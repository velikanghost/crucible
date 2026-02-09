import {
  Controller,
  Get,
  Post,
  Body,
  Query,
  HttpException,
  HttpStatus,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiQuery, ApiResponse } from '@nestjs/swagger';
import { GameService } from './game.service';
import { RegisterDto } from './dto/register.dto';

@ApiTags('game')
@Controller('game')
export class GameController {
  constructor(private readonly gameService: GameService) {}

  @Get('state')
  @ApiOperation({ summary: 'Get game state', description: 'Returns full game state, or agent-specific view when wallet is provided' })
  @ApiQuery({ name: 'wallet', required: false, description: 'Agent wallet address for personalized state' })
  @ApiResponse({ status: 200, description: 'Current game state' })
  async getState(@Query('wallet') wallet?: string) {
    if (wallet) {
      return this.gameService.getStateForAgent(wallet);
    }
    return this.gameService.getState();
  }

  @Post('register')
  @ApiOperation({ summary: 'Register an agent', description: 'Registers agent for the game. Optionally verifies Moltbook profile if username provided.' })
  @ApiResponse({ status: 201, description: 'Agent registered successfully' })
  @ApiResponse({ status: 400, description: 'Invalid Moltbook account or registration failed' })
  async register(@Body() dto: RegisterDto) {
    return this.gameService.registerAgent(
      dto.agentId,
      dto.walletAddress,
      dto.moltbookUsername,
    );
  }

  @Post('start')
  @ApiOperation({ summary: 'Start the game', description: 'Begins the game loop. Requires minimum player count to be met.' })
  @ApiResponse({ status: 201, description: 'Game started successfully' })
  @ApiResponse({ status: 400, description: 'Not enough players or game already running' })
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
