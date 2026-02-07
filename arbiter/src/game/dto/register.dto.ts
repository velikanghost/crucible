import { IsString, IsNotEmpty } from 'class-validator';
import { ApiProperty } from '@nestjs/swagger';

export class RegisterDto {
  @ApiProperty({ example: 'wrath-001', description: 'Unique agent identifier' })
  @IsString()
  @IsNotEmpty()
  readonly agentId: string;

  @ApiProperty({ example: '0x1234...abcd', description: 'Agent wallet address on Monad testnet' })
  @IsString()
  @IsNotEmpty()
  readonly walletAddress: string;

  @ApiProperty({ example: 'wrath_agent', description: 'Moltbook username (must be claimed)' })
  @IsString()
  @IsNotEmpty()
  readonly moltbookUsername: string;
}
