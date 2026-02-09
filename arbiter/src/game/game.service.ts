import { Injectable, Logger, BadRequestException } from '@nestjs/common';
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
  karma: number;
  is_claimed: boolean;
  owner?: {
    x_handle?: string;
    x_verified?: boolean;
  };
}

interface RegisteredAgent {
  walletAddress: string;
  moltbookUsername: string;
  karma: number;
}

@Injectable()
export class GameService {
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
    moltbookUsername: string,
  ): Promise<{ success: boolean; message: string }> {
    const profile = await this.verifyMoltbookProfile(moltbookUsername);

    if (!profile.is_claimed) {
      throw new BadRequestException(
        `Moltbook account @${moltbookUsername} is not claimed. Only verified agents can join.`,
      );
    }

    this.registeredAgents.set(agentId, {
      walletAddress,
      moltbookUsername,
      karma: profile.karma,
    });

    this.logger.log(
      `Agent ${agentId} (@${moltbookUsername}) registered with wallet ${walletAddress} | Karma: ${profile.karma}`,
    );

    this.gateway.emitPlayerJoined(agentId, walletAddress, moltbookUsername);

    return {
      success: true,
      message: `Verified! @${moltbookUsername} can now call register() on-chain with 0.5 MON.`,
    };
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
    this.phase = Phase.COMMIT;

    const prizePool = await this.chainService.getPrizePool();
    this.gateway.emitGameStarted(playerCount, prizePool);

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

    this.phase = Phase.COMMIT;
    await this.chainService.startRound();

    this.commitDeadline = Date.now() + GAME_CONFIG.commitWindow * 1000;
    this.gateway.emitRoundStart(this.round, this.commitDeadline);

    this.logger.log(`Commit phase: ${GAME_CONFIG.commitWindow}s window`);
    await this.sleep(GAME_CONFIG.commitWindow * 1000);

    this.phase = Phase.REVEAL;
    this.revealDeadline = Date.now() + GAME_CONFIG.revealWindow * 1000;
    this.gateway.emitRevealPhase(this.revealDeadline);

    this.logger.log(`Reveal phase: ${GAME_CONFIG.revealWindow}s window`);
    await this.sleep(GAME_CONFIG.revealWindow * 1000);

    const { results } = await this.chainService.resolveRound();
    this.roundHistory.push(results);

    const eliminatedPlayers = await this.findNewEliminations();

    this.gateway.emitRoundResults(this.round, results, eliminatedPlayers);
    this.logRoundResults(results, eliminatedPlayers);

    this.phase = Phase.RULES;
    this.gateway.emitRulePhase(this.round);

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

    this.gateway.emitGameOver(
      sorted.map((p) => ({ address: p.address, points: p.points })),
      winners.map((w, i) => ({ address: w, shareBps: shares[i] })),
    );

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

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
