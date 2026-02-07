import { Module } from '@nestjs/common';
import { MatchmakerService } from './matchmaker.service';

@Module({
  providers: [MatchmakerService],
  exports: [MatchmakerService],
})
export class CombatModule {}
