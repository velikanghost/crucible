import { Injectable, Logger, BadRequestException, OnModuleInit, OnModuleDestroy } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { ChainService } from '../chain/chain.service';
import { RulesService } from '../rules/rules.service';
import { GameGateway } from './game.gateway';
import { GAME_CONFIG } from '../common/config';
import {
  Phase,
  type GameState,
  type PlayerState,
  type CombatResult,
} from '../common/types';

interface MoltbookProfile {
  name: string;
  description?: string;
  is_claimed: boolean;
  owner?: {
    x_handle?: string;
    x_verified?: boolean;
  };
}

interface RegisteredAgent {
  walletAddress: string;
  moltbookUsername: string | null;
  callbackUrl: string | null;
  hookToken: string | null;
}

// On-chain phase enum values (from Crucible.sol)
const ON_CHAIN_PHASE = {
  LOBBY: 0,
  COMMIT: 1,
  REVEAL: 2,
  RULES: 3,
  ENDED: 4,
} as const;

@Injectable()
export class GameService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(GameService.name);
  private readonly MOLTBOOK_API_BASE: string;

  private phase: Phase = Phase.LOBBY;
  private round = 0;
  private commitDeadline = 0;
  private revealDeadline = 0;
  private registeredAgents: Map<string, RegisteredAgent> = new Map();
  private roundHistory: CombatResult[][] = [];
  private running = false;

  constructor(
    private readonly chainService: ChainService,
    private readonly rulesService: RulesService,
    private readonly gateway: GameGateway,
    private readonly configService: ConfigService,
  ) {
    this.MOLTBOOK_API_BASE = configService.get('MOLTBOOK_API_URL', 'https://www.moltbook.com/api/v1');
  }

  async onModuleInit(): Promise<void> {
    await this.recoverFromStaleState();
    this.startEventWatching();
  }

  onModuleDestroy(): void {
    if (this.autoStartTimer) {
      clearTimeout(this.autoStartTimer);
    }
    this.chainService.stopWatchingPlayerRegistered();
  }

  private startEventWatching(): void {
    this.chainService.watchPlayerRegistered((address) => {
      this.handlePlayerRegisteredEvent(address).catch((error) => {
        this.logger.error(`Error handling PlayerRegistered for ${address}:`, error);
      });
    });
  }

  private async handlePlayerRegisteredEvent(address: string): Promise<void> {
    if (this.phase !== Phase.LOBBY) {
      this.logger.warn(`PlayerRegistered for ${address} ignored: not in LOBBY`);
      return;
    }

    const existing = Array.from(this.registeredAgents.values()).find(
      (agent) => agent.walletAddress.toLowerCase() === address.toLowerCase(),
    );

    if (!existing) {
      const agentId = `player-${address.slice(2, 10).toLowerCase()}`;
      this.registeredAgents.set(agentId, {
        walletAddress: address,
        moltbookUsername: null,
        callbackUrl: null,
        hookToken: null,
      });
      this.logger.log(`On-chain registration detected: ${address.slice(0, 10)} (no webhook)`);
    } else {
      this.logger.log(`On-chain registration detected: ${address.slice(0, 10)} (already registered via API)`);
    }

    this.gateway.emitPlayerJoined(
      existing?.moltbookUsername ?? address.slice(0, 10),
      address,
      existing?.moltbookUsername ?? address.slice(0, 10),
    );

    const playerCount = await this.chainService.getPlayerCount();
    await this.notifyAgents('player:joined', {
      walletAddress: address,
      playerCount,
    });

    await this.checkAutoStart();
  }

  private async recoverFromStaleState(): Promise<void> {
    this.logger.log('Checking contract state on startup...');

    try {
      let onChainPhase = await this.chainService.getPhase();
      const phaseName = ['LOBBY', 'COMMIT', 'REVEAL', 'RULES', 'ENDED'][onChainPhase] ?? `UNKNOWN(${onChainPhase})`;

      if (onChainPhase === ON_CHAIN_PHASE.LOBBY) {
        const playerCount = await this.chainService.getPlayerCount();
        if (playerCount === 0) {
          this.logger.log('Contract is in clean LOBBY state. Ready for new game.');
          return;
        }

        this.logger.log(`Contract in LOBBY with ${playerCount} leftover players. Running cleanup cycle...`);
        await this.chainService.startGame();
        await this.chainService.startRound(1, 1);
        const revealDeadline = await this.chainService.getRevealDeadline();
        const waitMs = Math.max(0, (revealDeadline - Math.floor(Date.now() / 1000) + 2) * 1000);
        if (waitMs > 0) {
          this.logger.log(`Waiting ${Math.ceil(waitMs / 1000)}s for reveal deadline...`);
          await this.sleep(waitMs);
        }
        await this.chainService.resolveRound();
        onChainPhase = ON_CHAIN_PHASE.RULES;
      }

      if (onChainPhase !== ON_CHAIN_PHASE.LOBBY) {
        this.logger.log(`Contract stuck in ${phaseName} phase. Resetting to LOBBY...`);
      }

      if (onChainPhase === ON_CHAIN_PHASE.COMMIT || onChainPhase === ON_CHAIN_PHASE.REVEAL) {
        const revealDeadline = await this.chainService.getRevealDeadline();
        const waitMs = Math.max(0, (revealDeadline - Math.floor(Date.now() / 1000) + 2) * 1000);
        if (waitMs > 0) {
          this.logger.log(`Waiting ${Math.ceil(waitMs / 1000)}s for reveal deadline...`);
          await this.sleep(waitMs);
        }
        await this.chainService.resolveRound();
        onChainPhase = ON_CHAIN_PHASE.RULES;
      }

      if (onChainPhase === ON_CHAIN_PHASE.RULES) {
        const alivePlayers = await this.chainService.getAlivePlayers();
        const winners = alivePlayers.length > 0 ? [alivePlayers[0]] : [];
        const shares = winners.length > 0 ? [10000] : [];
        await this.chainService.endGame(winners, shares);
        onChainPhase = ON_CHAIN_PHASE.ENDED;
      }

      if (onChainPhase === ON_CHAIN_PHASE.ENDED) {
        await this.chainService.newGame();
      }

      this.phase = Phase.LOBBY;
      this.round = 0;
      this.commitDeadline = 0;
      this.revealDeadline = 0;
      this.registeredAgents.clear();
      this.roundHistory = [];
      this.running = false;
      this.logger.log('Contract reset to LOBBY. Ready for new game.');
    } catch (error) {
      this.logger.error('Failed to recover from stale state:', error);
      this.logger.warn('Arbiter may not function correctly until contract is manually reset.');
    }
  }

  async getState(): Promise<GameState> {
    const alivePlayers = await this.chainService.getAlivePlayers();
    const playerStates = await this.chainService.getAllPlayerInfo(alivePlayers);
    const activeRules = await this.chainService.getActiveRules();
    const prizePool = await this.chainService.getPrizePool();

    return {
      phase: this.phase,
      round: this.round,
      players: playerStates,
      activeRules,
      prizePool,
      commitDeadline: this.commitDeadline,
      revealDeadline: this.revealDeadline,
    };
  }

  async getStateForAgent(walletAddress: string): Promise<{
    phase: Phase;
    round: number;
    commitDeadline: number;
    revealDeadline: number;
    you: PlayerState | null;
    opponents: PlayerState[];
    activeRules: string[];
    prizePool: string;
    opponentHistory: Record<string, number[]>;
  }> {
    const alivePlayers = await this.chainService.getAlivePlayers();
    const playerStates = await this.chainService.getAllPlayerInfo(alivePlayers);
    const activeRules = await this.chainService.getActiveRules();
    const prizePool = await this.chainService.getPrizePool();

    const you = playerStates.find((p) => p.address.toLowerCase() === walletAddress.toLowerCase()) ?? null;
    const opponents = playerStates.filter(
      (p) => p.address.toLowerCase() !== walletAddress.toLowerCase(),
    );

    const opponentHistory: Record<string, number[]> = {};
    for (const opp of opponents) {
      opponentHistory[opp.address] = this.getOpponentHistory(opp.address);
    }

    return {
      phase: this.phase,
      round: this.round,
      commitDeadline: this.commitDeadline,
      revealDeadline: this.revealDeadline,
      you,
      opponents,
      activeRules: this.rulesService.formatRulesForAgents(activeRules),
      prizePool,
      opponentHistory,
    };
  }

  async registerAgent(
    agentId: string,
    walletAddress: string,
    moltbookUsername?: string,
    callbackUrl?: string,
    hookToken?: string,
  ): Promise<{ success: boolean; message: string }> {
    if (callbackUrl) {
      this.validateCallbackUrl(callbackUrl);
    }

    if (moltbookUsername) {
      const profile = await this.verifyMoltbookProfile(moltbookUsername);

      if (!profile.is_claimed) {
        throw new BadRequestException(
          `Moltbook account @${moltbookUsername} is not claimed. Only verified agents can join.`,
        );
      }
    }

    this.registeredAgents.set(agentId, {
      walletAddress,
      moltbookUsername: moltbookUsername ?? null,
      callbackUrl: callbackUrl ?? null,
      hookToken: hookToken ?? null,
    });

    const displayName = moltbookUsername ? `@${moltbookUsername}` : walletAddress.slice(0, 10);
    this.logger.log(
      `Agent ${agentId} (${displayName}) registered with wallet ${walletAddress}`,
    );

    this.gateway.emitPlayerJoined(agentId, walletAddress, moltbookUsername ?? agentId);

    this.notifyAgents('player:joined', {
      agentId,
      walletAddress,
      playerCount: this.registeredAgents.size,
    }).catch(() => {});

    this.checkAutoStart().catch(() => {});

    return {
      success: true,
      message: moltbookUsername
        ? `Verified! @${moltbookUsername} can now call register() on-chain with 0.5 MON.`
        : `Registered! ${agentId} can now call register() on-chain with 0.5 MON.`,
    };
  }

  private validateCallbackUrl(url: string): void {
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      throw new BadRequestException(`Invalid callbackUrl: ${url}`);
    }

    const hostname = parsed.hostname.toLowerCase();

    const blockedHostnames = ['localhost', '127.0.0.1', '0.0.0.0', '::1'];
    if (blockedHostnames.includes(hostname)) {
      throw new BadRequestException(
        `callbackUrl must be a publicly reachable URL, not ${hostname}. ` +
        `Your agent needs a public webhook endpoint (e.g. https://your-agent.openclaw.ai/hooks/agent).`,
      );
    }

    const privatePatterns = [
      /^10\./,
      /^172\.(1[6-9]|2\d|3[01])\./,
      /^192\.168\./,
    ];
    if (privatePatterns.some((p) => p.test(hostname))) {
      throw new BadRequestException(
        `callbackUrl must be a publicly reachable URL, not a private IP (${hostname}). ` +
        `Your agent needs a public webhook endpoint.`,
      );
    }

    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
      throw new BadRequestException(
        `callbackUrl must use http or https protocol, got ${parsed.protocol}`,
      );
    }
  }

  private async verifyMoltbookProfile(username: string): Promise<MoltbookProfile> {
    const url = `${this.MOLTBOOK_API_BASE}/agents/profile?name=${encodeURIComponent(username)}`;

    try {
      const response = await fetch(url);

      if (!response.ok) {
        if (response.status === 404) {
          throw new BadRequestException(
            `Moltbook account @${username} not found. Create an account at moltbook.com first.`,
          );
        }
        throw new BadRequestException(
          `Failed to verify Moltbook account: ${response.statusText}`,
        );
      }

      const data = (await response.json()) as { agent: MoltbookProfile };
      return data.agent;
    } catch (error) {
      if (error instanceof BadRequestException) {
        throw error;
      }
      this.logger.error(`Moltbook API error for @${username}:`, error);
      throw new BadRequestException(
        `Unable to verify Moltbook account. Please try again later.`,
      );
    }
  }

  private autoStartTimer: ReturnType<typeof setTimeout> | null = null;

  private async checkAutoStart(): Promise<void> {
    if (this.running || this.phase !== Phase.LOBBY) return;

    const playerCount = await this.chainService.getPlayerCount();
    if (playerCount < GAME_CONFIG.minPlayers) return;

    if (this.autoStartTimer) return;

    const delaySec = 30;
    this.logger.log(
      `${playerCount} players registered on-chain. Auto-starting in ${delaySec}s...`,
    );

    this.autoStartTimer = setTimeout(async () => {
      this.autoStartTimer = null;
      try {
        const currentCount = await this.chainService.getPlayerCount();
        if (currentCount >= GAME_CONFIG.minPlayers && !this.running) {
          this.logger.log(`Auto-starting game with ${currentCount} players`);
          await this.startGame();
        }
      } catch (error) {
        this.logger.error('Auto-start failed:', error);
      }
    }, delaySec * 1000);
  }

  private async notifyAgents(event: string, data: Record<string, unknown>): Promise<void> {
    const agents = Array.from(this.registeredAgents.values()).filter(
      (agent) => agent.callbackUrl,
    );

    if (agents.length === 0) return;

    const message = this.formatWebhookMessage(event, data);
    this.logger.log(`Sending webhook '${event}' to ${agents.length} agent(s)`);

    const promises = agents.map(async (agent) => {
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
      };
      if (agent.hookToken) {
        headers['Authorization'] = `Bearer ${agent.hookToken}`;
      }

      try {
        await fetch(agent.callbackUrl!, {
          method: 'POST',
          headers,
          body: JSON.stringify({
            message,
            name: 'Crucible',
            sessionKey: 'crucible-game',
            wakeMode: 'now',
          }),
          signal: AbortSignal.timeout(10000),
        });
      } catch (error) {
        this.logger.warn(
          `Webhook '${event}' failed for ${agent.walletAddress} → ${agent.callbackUrl}: ${error}`,
        );
      }
    });

    await Promise.allSettled(promises);
  }

  private formatWebhookMessage(
    event: string,
    data: Record<string, unknown>,
  ): string {
    const actionNames = ['NONE', 'DOMAIN', 'TECHNIQUE', 'COUNTER', 'FLEE'];

    switch (event) {
      case 'round:start': {
        const players = data.players as Array<{
          address: string;
          points: number;
        }>;
        const playerList = players
          .map((p) => `${p.address.slice(0, 10)} (${p.points} pts)`)
          .join(', ');
        const deadline = new Date(data.commitDeadline as number).toISOString();
        return (
          `CRUCIBLE ROUND ${data.round} — COMMIT PHASE.\n` +
          `Commit deadline: ${deadline}.\n` +
          `Players: ${playerList}.\n` +
          `Choose a target and action, compute your commit hash, and call commitAction(hash) on-chain before the deadline.`
        );
      }

      case 'phase:reveal': {
        const deadline = new Date(data.revealDeadline as number).toISOString();
        return (
          `CRUCIBLE ROUND ${data.round} — REVEAL PHASE.\n` +
          `Reveal deadline: ${deadline}.\n` +
          `Call revealAction(action, target, salt) on-chain NOW with your saved commit data from crucible-combat.json.`
        );
      }

      case 'round:results': {
        const results = data.results as Array<{
          player1: string;
          player2: string;
          p1Action: number;
          p2Action: number;
          winner: string | null;
          pointsTransferred: number;
        }>;
        const resultLines = results.map((r) => {
          const winLabel = r.winner
            ? r.winner.slice(0, 10)
            : 'DRAW';
          return `  ${r.player1.slice(0, 10)} (${actionNames[r.p1Action]}) vs ${r.player2.slice(0, 10)} (${actionNames[r.p2Action]}) → Winner: ${winLabel}, ${r.pointsTransferred} pts transferred`;
        });
        const eliminations = data.eliminations as string[];
        const players = data.players as Array<{
          address: string;
          points: number;
        }>;
        const standings = players
          .map((p) => `${p.address.slice(0, 10)}: ${p.points} pts`)
          .join(', ');
        let msg =
          `CRUCIBLE ROUND ${data.round} RESULTS:\n` +
          resultLines.join('\n') +
          `\nStandings: ${standings}`;
        if (eliminations.length > 0) {
          msg += `\nEliminated: ${eliminations.map((e) => e.slice(0, 10)).join(', ')}`;
        }
        return msg;
      }

      case 'phase:rules': {
        const rules = data.activeRules as string[];
        const ruleList =
          rules.length > 0 ? rules.join(', ') : 'none';
        return (
          `CRUCIBLE ROUND ${data.round} — RULES PHASE.\n` +
          `Active rules: ${ruleList}.\n` +
          `If you have 100+ points, you may call proposeRule(ruleType) on-chain.`
        );
      }

      case 'game:started':
        return (
          `THE CRUCIBLE HAS BEGUN!\n` +
          `${data.playerCount} players, prize pool: ${data.prizePool} wei.\n` +
          `Prepare for combat. The first round starts now.`
        );

      case 'game:over': {
        const standings = data.standings as Array<{
          address: string;
          points: number;
        }>;
        const standingLines = standings.map(
          (s, i) => `  ${i + 1}. ${s.address.slice(0, 10)}: ${s.points} pts`,
        );
        return (
          `THE CRUCIBLE IS OVER!\n` +
          `Final standings:\n${standingLines.join('\n')}`
        );
      }

      case 'player:joined':
        return `New player joined The Crucible. ${data.playerCount} players now registered.`;

      default:
        return `Crucible event: ${event}`;
    }
  }

  async startGame(): Promise<void> {
    if (this.running) {
      throw new Error('Game already running');
    }

    const playerCount = await this.chainService.getPlayerCount();
    if (playerCount < GAME_CONFIG.minPlayers) {
      throw new Error(`Need at least ${GAME_CONFIG.minPlayers} players`);
    }

    await this.chainService.startGame();
    this.round = 1;
    this.running = true;

    const prizePool = await this.chainService.getPrizePool();
    this.gateway.emitGameStarted(playerCount, prizePool);

    await this.notifyAgents('game:started', {
      playerCount,
      prizePool,
      round: this.round,
    });

    this.logger.log(`Game started with ${playerCount} players`);
    this.runGameLoop().catch((err) => {
      this.logger.error('Game loop fatal error:', err);
      this.running = false;
      this.phase = Phase.ENDED;
    });
  }

  private async runGameLoop(): Promise<void> {
    while (this.running && this.round <= GAME_CONFIG.maxRounds) {
      try {
        await this.runRound();

        const aliveCount = await this.chainService.getAliveCount();
        if (aliveCount <= 1) {
          this.logger.log('Game over: 1 or fewer players alive');
          break;
        }

        this.round++;
      } catch (error) {
        this.logger.error(`Round ${this.round} error:`, error);
        break;
      }
    }

    await this.endGame();
  }

  private async runRound(): Promise<void> {
    this.logger.log(`=== Round ${this.round} ===`);

    await this.chainService.startRound();
    this.phase = Phase.COMMIT;

    this.commitDeadline = Date.now() + GAME_CONFIG.commitWindow * 1000;
    this.gateway.emitRoundStart(this.round, this.commitDeadline);

    const alivePlayers = await this.chainService.getAlivePlayers();
    const playerStates = await this.chainService.getAllPlayerInfo(alivePlayers);
    await this.notifyAgents('round:start', {
      round: this.round,
      commitDeadline: this.commitDeadline,
      players: playerStates.map((p) => ({
        address: p.address,
        points: p.points,
        alive: p.alive,
      })),
    });

    this.logger.log(`Commit phase: ${GAME_CONFIG.commitWindow}s window`);
    await this.sleep(GAME_CONFIG.commitWindow * 1000);

    this.phase = Phase.REVEAL;
    this.revealDeadline = Date.now() + GAME_CONFIG.revealWindow * 1000;
    this.gateway.emitRevealPhase(this.revealDeadline);

    await this.notifyAgents('phase:reveal', {
      round: this.round,
      revealDeadline: this.revealDeadline,
    });

    this.logger.log(`Reveal phase: ${GAME_CONFIG.revealWindow}s window`);
    await this.sleep(GAME_CONFIG.revealWindow * 1000);

    // Wait for on-chain revealDeadline to pass (block.timestamp may lag wall clock)
    await this.waitForRevealDeadline();

    const { results } = await this.chainService.resolveRound();
    this.roundHistory.push(results);

    const eliminatedPlayers = await this.findNewEliminations();

    this.gateway.emitRoundResults(this.round, results, eliminatedPlayers);
    this.logRoundResults(results, eliminatedPlayers);

    const postRoundPlayers = await this.chainService.getAlivePlayers();
    const postRoundStates = await this.chainService.getAllPlayerInfo(postRoundPlayers);
    await this.notifyAgents('round:results', {
      round: this.round,
      results,
      eliminations: eliminatedPlayers,
      players: postRoundStates.map((p) => ({
        address: p.address,
        points: p.points,
        alive: p.alive,
      })),
    });

    this.phase = Phase.RULES;
    this.gateway.emitRulePhase(this.round);

    const activeRules = await this.chainService.getActiveRules();
    await this.notifyAgents('phase:rules', {
      round: this.round,
      activeRules: this.rulesService.formatRulesForAgents(activeRules),
    });

    this.logger.log(`Rules phase: ${GAME_CONFIG.ruleWindow}s window`);
    await this.sleep(GAME_CONFIG.ruleWindow * 1000);

    await this.chainService.advanceRound();
  }

  private async endGame(): Promise<void> {
    this.phase = Phase.ENDED;
    this.running = false;

    const alivePlayers = await this.chainService.getAlivePlayers();
    const playerStates = await this.chainService.getAllPlayerInfo(alivePlayers);

    const sorted = [...playerStates].sort((a, b) => b.points - a.points);

    const winner = sorted[0];
    if (!winner) {
      this.logger.warn('No alive players to distribute prizes to');
      return;
    }

    const { platformFeeAddress, platformFeeBps } = GAME_CONFIG;
    const hasFeeAddress = platformFeeAddress.length > 0;

    const winnerShareBps = hasFeeAddress ? 10000 - platformFeeBps : 10000;

    const winners: string[] = hasFeeAddress
      ? [winner.address, platformFeeAddress]
      : [winner.address];
    const shares: number[] = hasFeeAddress
      ? [winnerShareBps, platformFeeBps]
      : [winnerShareBps];

    await this.chainService.endGame(winners, shares);

    const standings = sorted.map((p) => ({ address: p.address, points: p.points }));
    const payouts = winners.map((w, i) => ({ address: w, shareBps: shares[i] }));

    this.gateway.emitGameOver(standings, payouts);

    await this.notifyAgents('game:over', { standings, payouts });

    this.logger.log('Game ended (winner-takes-all). Final standings:');
    sorted.forEach((p, i) => {
      this.logger.log(`  ${i + 1}. ${p.address}: ${p.points} pts`);
    });
    this.logger.log(`Winner: ${winner.address} (${winnerShareBps} bps)`);
    if (hasFeeAddress) {
      this.logger.log(`Platform fee: ${platformFeeAddress} (${platformFeeBps} bps)`);
    }

    await this.chainService.newGame();
    this.registeredAgents.clear();
    this.roundHistory = [];
    this.round = 0;
    this.commitDeadline = 0;
    this.revealDeadline = 0;
    this.phase = Phase.LOBBY;
    this.logger.log('Contract reset to LOBBY. Ready for new game.');
  }

  private getOpponentHistory(address: string): number[] {
    const actions: number[] = [];
    for (const roundResults of this.roundHistory) {
      for (const result of roundResults) {
        if (result.player1.toLowerCase() === address.toLowerCase()) {
          actions.push(result.p1Action);
        } else if (result.player2.toLowerCase() === address.toLowerCase()) {
          actions.push(result.p2Action);
        }
      }
    }
    return actions;
  }

  private async findNewEliminations(): Promise<string[]> {
    const alivePlayers = await this.chainService.getAlivePlayers();
    const allPlayers = await this.chainService.getPlayerCount();
    const eliminated: string[] = [];

    if (alivePlayers.length < allPlayers) {
      const lastResults = this.roundHistory[this.roundHistory.length - 1] ?? [];
      const involvedAddresses = new Set<string>();
      for (const result of lastResults) {
        involvedAddresses.add(result.player1.toLowerCase());
        involvedAddresses.add(result.player2.toLowerCase());
      }

      for (const addr of involvedAddresses) {
        const info = await this.chainService.getPlayerInfo(addr);
        if (!info.alive) {
          eliminated.push(addr);
        }
      }
    }

    return eliminated;
  }

  private logRoundResults(results: CombatResult[], eliminations: string[]) {
    const actionNames = ['NONE', 'DOMAIN', 'TECHNIQUE', 'COUNTER', 'FLEE'];
    for (const r of results) {
      const winnerLabel = r.winner ? r.winner.slice(0, 8) : 'DRAW';
      this.logger.log(
        `  ${r.player1.slice(0, 8)} (${actionNames[r.p1Action]}) vs ${r.player2.slice(0, 8)} (${actionNames[r.p2Action]}) → Winner: ${winnerLabel} | Transfer: ${r.pointsTransferred}`,
      );
    }
    if (eliminations.length > 0) {
      this.logger.log(`  Eliminated: ${eliminations.map((e) => e.slice(0, 8)).join(', ')}`);
    }
  }

  private async waitForRevealDeadline(): Promise<void> {
    for (let attempt = 0; attempt < 10; attempt++) {
      const onChainDeadline = await this.chainService.getRevealDeadline();
      const now = Math.floor(Date.now() / 1000);
      if (now >= onChainDeadline) {
        return;
      }
      const waitSec = onChainDeadline - now + 1;
      this.logger.log(`Block timestamp behind revealDeadline, waiting ${waitSec}s...`);
      await this.sleep(waitSec * 1000);
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
