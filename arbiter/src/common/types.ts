export enum Action {
  NONE = 0,
  DOMAIN = 1,
  TECHNIQUE = 2,
  COUNTER = 3,
  FLEE = 4,
}

export enum Phase {
  LOBBY = 'LOBBY',
  COMMIT = 'COMMIT',
  REVEAL = 'REVEAL',
  RULES = 'RULES',
  ENDED = 'ENDED',
}

export enum RuleType {
  NONE = 0,
  BLOOD_TAX = 1,
  BOUNTY_HUNTER = 2,
  EXPENSIVE_DOMAIN = 3,
  SANCTUARY = 4,
}

export interface PlayerState {
  readonly address: string;
  readonly points: number;
  readonly alive: boolean;
}

export interface CombatResult {
  readonly player1: string;
  readonly player2: string;
  readonly p1Action: Action;
  readonly p2Action: Action;
  readonly winner: string | null;
  readonly pointsTransferred: number;
}

export interface ActiveRule {
  readonly ruleType: RuleType;
  readonly proposer: string;
  readonly activatedAtRound: number;
}

export interface GameState {
  readonly phase: Phase;
  readonly round: number;
  readonly players: readonly PlayerState[];
  readonly activeRules: readonly ActiveRule[];
  readonly prizePool: string;
  readonly commitDeadline: number;
  readonly revealDeadline: number;
}

export interface RoundEvent {
  readonly type: string;
  readonly data: unknown;
}
