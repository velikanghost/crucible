import { Injectable, Logger } from '@nestjs/common';
import type { ActiveRule } from '../common/types';
import { RuleType } from '../common/types';

@Injectable()
export class RulesService {
  private readonly logger = new Logger(RulesService.name);

  describeRule(ruleType: RuleType): string {
    const descriptions: Record<RuleType, string> = {
      [RuleType.NONE]: 'No rule',
      [RuleType.BLOOD_TAX]: 'Blood Tax: Rule creator gets 10% of all earned points',
      [RuleType.BOUNTY_HUNTER]: 'Bounty Hunter: 2x points for defeating the leader',
      [RuleType.EXPENSIVE_DOMAIN]: 'Expensive Domain: Domain costs 50 instead of 30',
      [RuleType.SANCTUARY]: 'Sanctuary: Skip next combat round (cooldown)',
    };
    return descriptions[ruleType] ?? 'Unknown rule';
  }

  formatRulesForAgents(rules: readonly ActiveRule[]): string[] {
    return rules.map(
      (r) =>
        `[Round ${r.activatedAtRound}] ${this.describeRule(r.ruleType)} (proposed by ${r.proposer})`,
    );
  }
}
