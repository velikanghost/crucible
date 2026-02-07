import {
  Controller,
  Get,
  Post,
  Body,
  Query,
  HttpException,
  HttpStatus,
} from '@nestjs/common';
import { GameService } from './game.service';
import { RegisterDto } from './dto/register.dto';

@Controller('game')
export class GameController {
  constructor(private readonly gameService: GameService) {}

  @Get('state')
  async getState(@Query('wallet') wallet?: string) {
    if (wallet) {
      return this.gameService.getStateForAgent(wallet);
    }
    return this.gameService.getState();
  }

  @Post('register')
  async register(@Body() dto: RegisterDto) {
    return this.gameService.registerAgent(
      dto.agentId,
      dto.walletAddress,
      dto.moltbookUsername,
    );
  }

  @Post('start')
  async startGame() {
    try {
      await this.gameService.startGame();
      return { success: true, message: 'Game started' };
    } catch (error) {
      throw new HttpException(
        error instanceof Error ? error.message : 'Failed to start game',
        HttpStatus.BAD_REQUEST,
      );
    }
  }
}
