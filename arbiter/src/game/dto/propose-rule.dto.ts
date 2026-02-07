import { IsEnum } from 'class-validator';
import { RuleType } from '../../common/types';

export class ProposeRuleDto {
  @IsEnum(RuleType)
  readonly ruleType: RuleType;
}
