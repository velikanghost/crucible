import { IsString, IsNotEmpty } from 'class-validator';

export class RegisterDto {
  @IsString()
  @IsNotEmpty()
  readonly agentId: string;

  @IsString()
  @IsNotEmpty()
  readonly walletAddress: string;

  @IsString()
  @IsNotEmpty()
  readonly moltbookUsername: string;
}
