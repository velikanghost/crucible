import { Module } from '@nestjs/common';
import { GameController } from './game.controller';
import { GameService } from './game.service';
import { GameGateway } from './game.gateway';
import { ChainModule } from '../chain/chain.module';
import { CombatModule } from '../combat/combat.module';
import { RulesModule } from '../rules/rules.module';

@Module({
  imports: [ChainModule, CombatModule, RulesModule],
  controllers: [GameController],
  providers: [GameService, GameGateway],
})
export class GameModule {}
