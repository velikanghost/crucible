import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  parseEventLogs,
  type Address,
  type Hash,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { GAME_CONFIG } from '../common/config';
import { CRUCIBLE_ABI } from './crucible.abi';
import type { PlayerState, ActiveRule, CombatResult } from '../common/types';

const monadTestnet = defineChain({
  id: 10143,
  name: 'Monad Testnet',
  nativeCurrency: { name: 'MON', symbol: 'MON', decimals: 18 },
  rpcUrls: {
    default: { http: ['https://testnet-rpc.monad.xyz'] },
  },
});

@Injectable()
export class ChainService implements OnModuleInit {
  private readonly logger = new Logger(ChainService.name);
  private publicClient: ReturnType<typeof createPublicClient>;
  private walletClient: ReturnType<typeof createWalletClient>;
  private contractAddress: Address;

  constructor(private readonly configService: ConfigService) {}

  onModuleInit() {
    const arbiterPrivateKey = this.configService.get<string>('ARBITER_PRIVATE_KEY', '');
    const contractAddress = this.configService.get<string>('CRUCIBLE_ADDRESS', '');
    const rpcUrl = this.configService.get<string>('MONAD_RPC_URL', 'https://testnet-rpc.monad.xyz');

    if (!arbiterPrivateKey || !contractAddress) {
      this.logger.warn(
        'Chain config missing. Set ARBITER_PRIVATE_KEY and CRUCIBLE_ADDRESS env vars.',
      );
      return;
    }

    const account = privateKeyToAccount(arbiterPrivateKey as `0x${string}`);
    this.contractAddress = contractAddress as Address;

    const transport = http(rpcUrl);

    this.publicClient = createPublicClient({ chain: monadTestnet, transport });
    this.walletClient = createWalletClient({
      account,
      chain: monadTestnet,
      transport,
    });

    this.logger.log(`Chain service initialized. Contract: ${this.contractAddress}`);
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private async writeContract(params: Record<string, any>): Promise<Hash> {
    const hash = await this.walletClient.writeContract({
      ...params,
      chain: monadTestnet,
    } as unknown as Parameters<typeof this.walletClient.writeContract>[0]);
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  async startGame(): Promise<Hash> {
    const hash = await this.writeContract({
      address: this.contractAddress,
      abi: CRUCIBLE_ABI,
      functionName: 'startGame',
    });
    this.logger.log(`startGame tx: ${hash}`);
    return hash;
  }

  async startRound(): Promise<Hash> {
    const hash = await this.writeContract({
      address: this.contractAddress,
      abi: CRUCIBLE_ABI,
      functionName: 'startRound',
      args: [
        BigInt(GAME_CONFIG.commitWindow),
        BigInt(GAME_CONFIG.revealWindow),
      ],
    });
    this.logger.log(`startRound tx: ${hash}`);
    return hash;
  }

  async resolveRound(): Promise<{ hash: Hash; results: CombatResult[] }> {
    const hash = await this.writeContract({
      address: this.contractAddress,
      abi: CRUCIBLE_ABI,
      functionName: 'resolveRound',
    });

    const receipt = await this.publicClient.waitForTransactionReceipt({ hash });

    type CombatResolvedArgs = {
      player1: Address;
      player2: Address;
      p1Action: number;
      p2Action: number;
      winner: Address;
      pointsTransferred: bigint;
    };

    const events = parseEventLogs({
      abi: CRUCIBLE_ABI,
      logs: receipt.logs,
      eventName: 'CombatResolved',
    }) as unknown as ReadonlyArray<{ args: CombatResolvedArgs }>;

    const results: CombatResult[] = events.map((e) => ({
      player1: e.args.player1,
      player2: e.args.player2,
      p1Action: Number(e.args.p1Action),
      p2Action: Number(e.args.p2Action),
      winner: e.args.winner === '0x0000000000000000000000000000000000000000'
        ? null
        : e.args.winner,
      pointsTransferred: Number(e.args.pointsTransferred),
    }));

    this.logger.log(`resolveRound tx: ${hash}, results: ${results.length}`);
    return { hash, results };
  }

  async advanceRound(): Promise<Hash> {
    const hash = await this.writeContract({
      address: this.contractAddress,
      abi: CRUCIBLE_ABI,
      functionName: 'advanceRound',
    });
    this.logger.log(`advanceRound tx: ${hash}`);
    return hash;
  }

  async endGame(
    winners: readonly string[],
    shares: readonly number[],
  ): Promise<Hash> {
    const hash = await this.writeContract({
      address: this.contractAddress,
      abi: CRUCIBLE_ABI,
      functionName: 'endGame',
      args: [
        winners as Address[],
        shares.map((s) => BigInt(s)),
      ],
    });
    this.logger.log(`endGame tx: ${hash}`);
    return hash;
  }

  async newGame(): Promise<Hash> {
    const hash = await this.writeContract({
      address: this.contractAddress,
      abi: CRUCIBLE_ABI,
      functionName: 'newGame',
    });
    this.logger.log(`newGame tx: ${hash}`);
    return hash;
  }

  async getAlivePlayers(): Promise<string[]> {
    const result = await this.publicClient.readContract({
      address: this.contractAddress,
      abi: CRUCIBLE_ABI,
      functionName: 'getAlivePlayers',
    });
    return result as string[];
  }

  async getPlayerInfo(address: string): Promise<PlayerState> {
    const [points, alive, registered] = (await this.publicClient.readContract({
      address: this.contractAddress,
      abi: CRUCIBLE_ABI,
      functionName: 'getPlayerInfo',
      args: [address as Address],
    })) as [bigint, boolean, boolean];

    return {
      address,
      points: Number(points),
      alive,
      registered,
    };
  }

  async getAllPlayerInfo(addresses: readonly string[]): Promise<PlayerState[]> {
    const results = await Promise.all(
      addresses.map((addr) => this.getPlayerInfo(addr)),
    );
    return results;
  }

  async getActiveRules(): Promise<ActiveRule[]> {
    const result = await this.publicClient.readContract({
      address: this.contractAddress,
      abi: CRUCIBLE_ABI,
      functionName: 'getActiveRules',
    });

    return (result as Array<{ ruleType: number; proposer: string; activatedAtRound: bigint }>).map(
      (r) => ({
        ruleType: r.ruleType,
        proposer: r.proposer,
        activatedAtRound: Number(r.activatedAtRound),
      }),
    );
  }

  async getCurrentRound(): Promise<number> {
    const result = await this.publicClient.readContract({
      address: this.contractAddress,
      abi: CRUCIBLE_ABI,
      functionName: 'currentRound',
    });
    return Number(result);
  }

  async getPrizePool(): Promise<string> {
    const result = await this.publicClient.readContract({
      address: this.contractAddress,
      abi: CRUCIBLE_ABI,
      functionName: 'prizePool',
    }) as bigint;
    return result.toString();
  }

  async getPlayerCount(): Promise<number> {
    const result = await this.publicClient.readContract({
      address: this.contractAddress,
      abi: CRUCIBLE_ABI,
      functionName: 'getPlayerCount',
    });
    return Number(result);
  }

  async getAliveCount(): Promise<number> {
    const result = await this.publicClient.readContract({
      address: this.contractAddress,
      abi: CRUCIBLE_ABI,
      functionName: 'getAliveCount',
    });
    return Number(result);
  }
}
