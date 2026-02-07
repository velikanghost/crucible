export const GAME_CONFIG = {
  commitWindow: 30,
  revealWindow: 15,
  ruleWindow: 20,
  minPlayers: 2,
  maxRounds: 20,
} as const;

export const CHAIN_CONFIG = {
  rpcUrl: process.env.MONAD_RPC_URL ?? 'https://testnet-rpc.monad.xyz',
  contractAddress: process.env.CRUCIBLE_ADDRESS ?? '',
  arbiterPrivateKey: process.env.ARBITER_PRIVATE_KEY ?? '',
} as const;
