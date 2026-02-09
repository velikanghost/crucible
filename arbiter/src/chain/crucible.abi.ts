export const CRUCIBLE_ABI = [
  {
    type: 'constructor',
    inputs: [
      { name: '_arbiter', type: 'address' },
      { name: '_entryFee', type: 'uint256' },
      { name: '_startingPoints', type: 'int256' },
    ],
  },
  {
    type: 'function',
    name: 'startGame',
    inputs: [],
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'setMatchups',
    inputs: [
      {
        name: '_matchups',
        type: 'tuple[]',
        components: [
          { name: 'player1', type: 'address' },
          { name: 'player2', type: 'address' },
        ],
      },
      { name: '_commitWindow', type: 'uint256' },
      { name: '_revealWindow', type: 'uint256' },
    ],
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'resolveRound',
    inputs: [],
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'advanceRound',
    inputs: [],
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'endGame',
    inputs: [
      { name: '_winners', type: 'address[]' },
      { name: '_shares', type: 'uint256[]' },
    ],
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'newGame',
    inputs: [],
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'phase',
    inputs: [],
    outputs: [{ type: 'uint8' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'currentRound',
    inputs: [],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'commitDeadline',
    inputs: [],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'revealDeadline',
    inputs: [],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'prizePool',
    inputs: [],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'getPlayerCount',
    inputs: [],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'getAliveCount',
    inputs: [],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'getAlivePlayers',
    inputs: [],
    outputs: [{ type: 'address[]' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'getActiveRules',
    inputs: [],
    outputs: [
      {
        type: 'tuple[]',
        components: [
          { name: 'ruleType', type: 'uint8' },
          { name: 'proposer', type: 'address' },
          { name: 'activatedAtRound', type: 'uint256' },
        ],
      },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'getCurrentMatchups',
    inputs: [],
    outputs: [
      {
        type: 'tuple[]',
        components: [
          { name: 'player1', type: 'address' },
          { name: 'player2', type: 'address' },
        ],
      },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'getPlayerInfo',
    inputs: [{ name: '_player', type: 'address' }],
    outputs: [
      { name: 'points', type: 'int256' },
      { name: 'alive', type: 'bool' },
      { name: 'registered', type: 'bool' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'getCommitment',
    inputs: [
      { name: '_round', type: 'uint256' },
      { name: '_player', type: 'address' },
    ],
    outputs: [
      { name: 'committed', type: 'bool' },
      { name: 'revealed', type: 'bool' },
      { name: 'action', type: 'uint8' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'event',
    name: 'PlayerRegistered',
    inputs: [{ name: 'player', type: 'address', indexed: true }],
  },
  {
    type: 'event',
    name: 'GameStarted',
    inputs: [
      { name: 'playerCount', type: 'uint256', indexed: false },
      { name: 'prizePool', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'MatchupsSet',
    inputs: [
      { name: 'round', type: 'uint256', indexed: true },
      { name: 'commitDeadline', type: 'uint256', indexed: false },
      { name: 'revealDeadline', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'ActionCommitted',
    inputs: [
      { name: 'round', type: 'uint256', indexed: true },
      { name: 'player', type: 'address', indexed: true },
    ],
  },
  {
    type: 'event',
    name: 'ActionRevealed',
    inputs: [
      { name: 'round', type: 'uint256', indexed: true },
      { name: 'player', type: 'address', indexed: true },
      { name: 'action', type: 'uint8', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'CombatResolved',
    inputs: [
      { name: 'round', type: 'uint256', indexed: true },
      { name: 'player1', type: 'address', indexed: true },
      { name: 'player2', type: 'address', indexed: true },
      { name: 'p1Action', type: 'uint8', indexed: false },
      { name: 'p2Action', type: 'uint8', indexed: false },
      { name: 'winner', type: 'address', indexed: false },
      { name: 'pointsTransferred', type: 'int256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'PlayerEliminated',
    inputs: [
      { name: 'player', type: 'address', indexed: true },
      { name: 'round', type: 'uint256', indexed: true },
    ],
  },
  {
    type: 'event',
    name: 'RuleProposed',
    inputs: [
      { name: 'proposer', type: 'address', indexed: true },
      { name: 'ruleType', type: 'uint8', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'RoundAdvanced',
    inputs: [{ name: 'round', type: 'uint256', indexed: true }],
  },
  {
    type: 'event',
    name: 'GameEnded',
    inputs: [{ name: 'totalRounds', type: 'uint256', indexed: false }],
  },
  {
    type: 'event',
    name: 'PayoutClaimed',
    inputs: [
      { name: 'player', type: 'address', indexed: true },
      { name: 'amount', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'NewGame',
    inputs: [],
  },
] as const;
