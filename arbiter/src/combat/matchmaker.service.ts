import { Injectable, Logger } from '@nestjs/common';
import type { Matchup } from '../common/types';

@Injectable()
export class MatchmakerService {
  private readonly logger = new Logger(MatchmakerService.name);

  pairPlayers(alivePlayers: readonly string[]): Matchup[] {
    const shuffled = [...alivePlayers].sort(() => Math.random() - 0.5);
    const pairs: Matchup[] = [];

    for (let i = 0; i < shuffled.length - 1; i += 2) {
      pairs.push({
        player1: shuffled[i],
        player2: shuffled[i + 1],
      });
    }

    if (shuffled.length % 2 !== 0) {
      this.logger.log(`Player ${shuffled[shuffled.length - 1]} gets a bye this round`);
    }

    this.logger.log(`Generated ${pairs.length} matchups from ${alivePlayers.length} players`);
    return pairs;
  }
}
