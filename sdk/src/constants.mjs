// The production deployment on Sepolia (docs/deployments.md). The Safe owns the pool and the policy.
export const CHAIN_ID = 11155111;
export const POOL = "0xaEe51E82965Ec1DeD870F3f4c248Ad4AdDc3e1cb";
export const AMOUNT_POLICY = "0x660f66ab31Ca9919D9e1770FEDc88Ff2dd29CE59";
export const VERIFIER = "0xDA9dD4A3e957AFD2179131273C93dabBA1186A44";
export const TOPIC = "/nox-shield/1/proof/proto";
export const NOT_BEFORE_GRID = 600;
export const WORDS = 13;       // public words per statement
export const LIMBS = 37;       // Goldilocks limbs per statement; limb 36 is the not-before time
export const P = 0xffffffff00000001n;
export const ASSET = { ETH: 0n, NOX: 1n };
export const SUBMITTER = [1n, 0n, 0n, 0n]; // fee recipient limbs 32..35: address(1), whoever lands the proof
// Public RPCs to read from. Logs are never trusted from one alone: publicnode has returned partial
// and empty log sets for ranges that hold spends.
export const RPCS = ["https://sepolia.gateway.tenderly.co", "https://ethereum-sepolia-rpc.publicnode.com"];
