import {
  WebSocketGateway,
  WebSocketServer,
  OnGatewayConnection,
  OnGatewayDisconnect,
} from '@nestjs/websockets';
import { Logger } from '@nestjs/common';
import { Server, Socket } from 'socket.io';

@WebSocketGateway({ cors: true })
export class GameGateway implements OnGatewayConnection, OnGatewayDisconnect {
  private readonly logger = new Logger(GameGateway.name);

  @WebSocketServer()
  server: Server;

  handleConnection(client: Socket) {
    this.logger.log(`Agent connected: ${client.id}`);
  }

  handleDisconnect(client: Socket) {
    this.logger.log(`Agent disconnected: ${client.id}`);
  }

  broadcast(event: string, data: unknown) {
    this.server.emit(event, data);
    this.logger.log(`Broadcast: ${event}`);
  }

  emitRoundStart(round: number, commitDeadline: number) {
    this.broadcast('round:start', { round, commitDeadline });
  }

  emitRevealPhase(revealDeadline: number) {
    this.broadcast('phase:reveal', { revealDeadline });
  }

  emitRoundResults(round: number, results: unknown[], eliminations: string[]) {
    this.broadcast('round:results', { round, results, eliminations });
  }

  emitRuleAdded(ruleType: number, proposer: string) {
    this.broadcast('rule:added', { ruleType, proposer });
  }

  emitRulePhase(round: number) {
    this.broadcast('phase:rules', { round });
  }

  emitGameOver(standings: unknown[], payouts: unknown[]) {
    this.broadcast('game:over', { standings, payouts });
  }

  emitGameStarted(playerCount: number, prizePool: string) {
    this.broadcast('game:started', { playerCount, prizePool });
  }

  emitPlayerJoined(agentId: string, walletAddress: string, moltbookUsername: string) {
    this.broadcast('player:joined', { agentId, walletAddress, moltbookUsername });
  }

  emitActionCommitted(walletAddress: string) {
    this.broadcast('action:committed', { walletAddress });
  }

  emitActionRevealed(walletAddress: string, action: number) {
    this.broadcast('action:revealed', { walletAddress, action });
  }
}
