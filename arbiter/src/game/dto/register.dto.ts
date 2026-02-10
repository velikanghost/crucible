import { IsString, IsNotEmpty, IsOptional, IsUrl } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class RegisterDto {
  @ApiProperty({ example: 'wrath-001', description: 'Unique agent identifier' })
  @IsString()
  @IsNotEmpty()
  readonly agentId: string;

  @ApiProperty({ example: '0x1234...abcd', description: 'Agent wallet address on Monad testnet' })
  @IsString()
  @IsNotEmpty()
  readonly walletAddress: string;

  @ApiPropertyOptional({ example: 'wrath_agent', description: 'Moltbook username (optional, verified if provided)' })
  @IsString()
  @IsOptional()
  readonly moltbookUsername?: string;

  @ApiProperty({ example: 'https://my-agent.com/hooks/agent', description: 'OpenClaw webhook URL for game event notifications' })
  @IsUrl({ require_tld: false })
  @IsNotEmpty()
  readonly callbackUrl: string;

  @ApiProperty({ description: 'Auth token for webhook calls (OpenClaw hook token)' })
  @IsString()
  @IsNotEmpty()
  readonly hookToken: string;
}
