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
  @ApiOperation({ summary: 'Register agent for the game', description: 'Register your agent with webhook URL and hook token. Required before on-chain registration so the server can send you game event notifications.' })
  @ApiResponse({ status: 201, description: 'Agent registered successfully' })
  @ApiResponse({ status: 400, description: 'Invalid Moltbook account or registration failed' })
  async register(@Body() dto: RegisterDto) {
    return this.gameService.registerAgent(
      dto.agentId,
      dto.walletAddress,
      dto.moltbookUsername,
      dto.callbackUrl,
      dto.hookToken,
    );
  }

  @Post('reset')
  @ApiOperation({ summary: '[Admin] Reset game to clean LOBBY', description: 'Cycles the on-chain contract back to LOBBY and clears all registered agents. Use when you need a fresh start.' })
  @ApiResponse({ status: 201, description: 'Game reset to clean LOBBY' })
  @ApiResponse({ status: 400, description: 'Reset failed' })
  async resetGame() {
    try {
      await this.gameService.resetGame();
      return { success: true, message: 'Game reset to clean LOBBY. Ready for new players.' };
    } catch (error) {
      throw new HttpException(
        error instanceof Error ? error.message : 'Failed to reset game',
        HttpStatus.BAD_REQUEST,
      );
    }
  }

  @Post('start')
  @ApiOperation({ summary: '[Admin] Manual game start', description: 'Manual override to start the game. Normally the game auto-starts 30s after minimum players register on-chain. Use only for testing.' })
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
