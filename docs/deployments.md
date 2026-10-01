# Deployments

Every NOX Shield contract on Sepolia (chain id 11155111); nothing is deployed on mainnet. The same
addresses, machine-readable, are in [`deployments/sepolia.env`](../deployments/sepolia.env) and
[`deployments/sepolia-launch.env`](../deployments/sepolia-launch.env). Some contracts were deployed under
older source names: see [deployed names](deployed-names.md). The Safe
`0xD4251BA8bD4F68690BaB9f27d544819cFBE11854` owns the pool, the amount policy and the fee router.

## The production pool

This is the pool the apps use. Statements are 13 words (37 limbs); word 12 is the not-before time on a
600-second grid.

| Contract | Address |
|---|---|
| ShieldedPool | [`0xaEe51E82965Ec1DeD870F3f4c248Ad4AdDc3e1cb`](https://sepolia.etherscan.io/address/0xaEe51E82965Ec1DeD870F3f4c248Ad4AdDc3e1cb) |
| AmountPolicy | [`0x660f66ab31Ca9919D9e1770FEDc88Ff2dd29CE59`](https://sepolia.etherscan.io/address/0x660f66ab31Ca9919D9e1770FEDc88Ff2dd29CE59) |
| Verifier (three shapes) | [`0xDA9dD4A3e957AFD2179131273C93dabBA1186A44`](https://sepolia.etherscan.io/address/0xDA9dD4A3e957AFD2179131273C93dabBA1186A44) |
| Evaluator | [`0x112aA1E495B7e1361e102f71c5190f72E5b734D2`](https://sepolia.etherscan.io/address/0x112aA1E495B7e1361e102f71c5190f72E5b734D2) |
| Evaluator code, parts 0 to 2 | `0x063034d093581d9282cf568cebd50caf399f5db0`, `0x3c8ba3add1f13b7e80807b8bf2dc5f663c1c0dff`, `0x8d8109e585a3e7db1930a942fd68ca6d2a0b650d` |
| Prepare, shapes A, A′, B | `0xb675b1f38fd6bc37b2792f7675faa830291306c6`, `0x2ea3dec8a79a8110f5bbc3ca304911eb7f17cdd3`, `0x2e1edbb148d6a2129e2b9b1f8f4562d2c4e91960` |
| Walk, shapes A, A′, B | `0x1f0b4700f4c5d62cd7b48b116d6effaaa09af0a5`, `0x1f24694d8cd4697b6aada1ad9dcdfc56d9a335b3`, `0xebe29d5b0b7a61abf422cfe322df6ff7b5b37c24` |
| ShieldFeeRouter | [`0x0Be77d3cF5Dd8989254e1f75B5D520f483603f6D`](https://sepolia.etherscan.io/address/0x0Be77d3cF5Dd8989254e1f75B5D520f483603f6D) |
| RootBounty | [`0x0DBdEA16938d8c7efd54fBf5CEFE20EF31FA4cAd`](https://sepolia.etherscan.io/address/0x0DBdEA16938d8c7efd54fBf5CEFE20EF31FA4cAd) |
| Tree hasher (Poseidon over Goldilocks) | [`0x87d55a0257Af7e495F288db340cDD169Cd1D544E`](https://sepolia.etherscan.io/address/0x87d55a0257Af7e495F288db340cDD169Cd1D544E) |
| AssociationSetRegistry | [`0xF6B5c3470eb7F1bdE3412E72Eff4235A4536a206`](https://sepolia.etherscan.io/address/0xF6B5c3470eb7F1bdE3412E72Eff4235A4536a206) |
| LinkRegistry | [`0xf1DC54d83b21D416ce619fA8C2E29C8381594225`](https://sepolia.etherscan.io/address/0xf1DC54d83b21D416ce619fA8C2E29C8381594225) |

The evaluator code parts hold data, not source: each one's runtime code is a slice of the evaluator,
and the verifier pins all of them by code hash.

**Verifier pins.** Image hash `0x4364151e9f54797f3bbf9c8d28465f5a7dcf8ca1aafa9c9b48eb43cedf4e2429`.
Periodic root `0x898b800f60f467f04ac9140fb425cd54181e4d1642f61fc38b5965d08ace2888`. Parameter ids:

| Shape | Queries | Parameter id |
|---|---|---|
| A | 19 | `0xccba76ed5748b5ee54dfd62935fd1d10998b5c0f84e35a9dc899905cfb1eadb5` |
| A′ | 18 | `0x9a15f4ba74bab7fb97df9245b02c80a1f6a2aff41471c3d26483a6248f8b7acf` |
| B | 17 | `0x4ef4256faa865857cce2cf3ea7c54cd4617dfc9dbb3d158393da9f02446a3350` |

`soundnessBits()` returns 135 conjectured and 80 provable. The query phase at shape A gives 80.8 bits;
the provable figure is 80.1.

**Fees**, read from the amount policy:

| | ETH | NOX |
|---|---|---|
| Deposit | 0.50% | 0.50% |
| Withdrawal, protocol part | 0.50% | 0.50% |
| Private transfer, protocol part | 0.0005 ETH | 400 NOX |
| Gas rungs, paid to the lander | 0.0025, 0.005, 0.01, 0.02 ETH | 2,000, 4,000, 8,000, 16,000 NOX |

A proof landed by someone else pays the protocol part plus exactly one rung; a proof its owner lands
pays the protocol part only. The fee router splits what it receives 40% to staking, 20% to anonymity
providers, 20% to the treasury and 20% to a burn. A change to 50% staking, 40% treasury and 10% burn is
queued behind the router's 48-hour timelock and can be put in force from 3 October 2026, 14:26 UTC.

**Receipts.** The first transfer on this pool: [`0x93bd48ea…2d0d`](https://sepolia.etherscan.io/tx/0x93bd48eab8253ce497afbdc3fca7071a1d24a73599c866bd599101e301d2ec0d),
3,934,660 gas, the 0.0025 ETH rung paid to its lander.

## Tokens and supporting contracts

| Contract | Address |
|---|---|
| NOX (Sepolia) | [`0x3E5249A65CA513D5e11260222e0D26f46b465d36`](https://sepolia.etherscan.io/address/0x3E5249A65CA513D5e11260222e0D26f46b465d36) |
| Faucet | [`0x871bc3AD5DA20c399d631817637cB5FB29eB04B4`](https://sepolia.etherscan.io/address/0x871bc3AD5DA20c399d631817637cB5FB29eB04B4) |
| Staking that receives the router's staking share | [`0x739e06586305c4a543d5cFd5fE5506aA289cf397`](https://sepolia.etherscan.io/address/0x739e06586305c4a543d5cFd5fE5506aA289cf397) |
| Safe (owner) | [`0xD4251BA8bD4F68690BaB9f27d544819cFBE11854`](https://sepolia.etherscan.io/address/0xD4251BA8bD4F68690BaB9f27d544819cFBE11854) |
| Guardian (may pause, cannot move funds) | `0x6B02855b93f946643cbE1b499308645B59423188` |

## Earlier pools

Notes in earlier pools stay spendable; deposits there are closed or closing.

| Pool | Address | State |
|---|---|---|
| Previous pool (12-word statements, flat fee) | `0xd0dbce195c082da39a218c62c01a732ce5b4d541` | open for spends; deposits close after the apps move |
| Launch pool | `0x8e377752c8890e23a1e9f40ebbd41183fc6949e2` | deposits paused since block 11,785,998 |
| A pool superseded at deployment | `0x00DB5e6E92F590Af3A6a857cf2C12F085271a976` | deposits paused |

## Landers

Five landers serve the production pool, each reachable through its own Tor onion service with the same
API (`/v1/info`, `/v1/status`, `POST /v1/handoff`, `GET /v1/handoff/<id>`). Anyone can run another: see
[running a lander](tutorials/02-run-a-lander.md).

| | Onion |
|---|---|
| 1 | `mforujillfk4w5h2zqgxdzendn3qb2zes4r2h57ownojshhmtcdzgdyd.onion` |
| 2 | `lfpw5uoslfiqmwsc7o2d2qts3grmfnixrhae3hkgkv6x4dlxpvafp4yd.onion` |
| 3 | `7ywwruseitmycfjwh2upbecetm6edej7pkxpp4xtzmtioes4ubs63kad.onion` |
| 4 | `g7uyxmffgim7sneprrkdp4ecshupvd3kuaadho6f7e2gcd3gazimriyd.onion` |
| 5 | `ewjq3ue43pclh6qyx3triup7org64nykbjgy7tmderlzzx27kstfdiqd.onion` |

## Source verification

Each contract below has a public Sourcify record showing that its published source compiles to exactly the
bytecode on chain, both the creation code and the runtime code. Check any of them at
`https://sourcify.dev/server/v2/contract/11155111/<address>`.

| Contract | Address | Sourcify |
|---|---|---|
| ShieldedPool | `0xaEe51E82965Ec1DeD870F3f4c248Ad4AdDc3e1cb` | exact match |
| AmountPolicy | `0x660f66ab31Ca9919D9e1770FEDc88Ff2dd29CE59` | exact match |
| Verifier | `0xDA9dD4A3e957AFD2179131273C93dabBA1186A44` | exact match |
| Prepare A, A′, B | `0xb675…06c6`, `0x2ea3…cdd3`, `0x2e1e…1960` | exact match |
| Walk A, A′, B | `0x1f0b…f0a5`, `0x1f24…35b3`, `0xebe2…7c24` | exact match |
| ShieldFeeRouter | `0x0Be77d3cF5Dd8989254e1f75B5D520f483603f6D` | exact match |
| RootBounty | `0x0DBdEA16938d8c7efd54fBf5CEFE20EF31FA4cAd` | exact match |
| LinkRegistry | `0xf1DC54d83b21D416ce619fA8C2E29C8381594225` | match |
| Faucet | `0x871bc3AD5DA20c399d631817637cB5FB29eB04B4` | exact match |
| NOX (proxy) | `0x3E5249A65CA513D5e11260222e0D26f46b465d36` | match |
| Staking | `0x739e06586305c4a543d5cFd5fE5506aA289cf397` | match |

"Match" means the code matches with different metadata, usually comments or file paths.

## Every other address these documents cite

The previous pool's verifier stack, and the launch stack with the accounts that served it, kept for the
receipts in [19](19-deployments-and-receipts.md).

| Contract | Address |
|---|---|
| Previous pool: AmountPolicy | `0xf4a8e6e39e08a93c635a1db8be4ecf1f6541444e` |
| Previous pool: verifier (three shapes) | `0xde6110142b39730f480f9d66c408f150a7e823c1` |
| Previous pool: evaluator | `0x8f9efa664cb76afca63e92639f3706a5dfa46975` |
| Previous pool: evaluator code, parts 0 to 2 | `0x420485eec0a3ef8078e2608f768f1d57e4f319d3`, `0xcddb80f4c405127ec04a0f860269b3379bfd2753`, `0x36c38813149231ba1ab1e29777a167f4715991b1` |
| Previous pool: prepare, shapes A, A′, B | `0x345ba9bd573c86f6aef27b9bfabc4109d11e4c17`, `0xe6e41d2eba77450af489933438586d71c8637f28`, `0x19f3b963f861232aef86558e81059f0f7bd85b0f` |
| Previous pool: walk, shapes A, A′, B | `0xd9f7bcc49bfdab364324c6e9f769ed0484eb78a6`, `0xcf41ea6702f9c2af1cedfe8a0cb6ae4cb14ba756`, `0x1e237dc5ecaa03c88a447a6384ae88149a701841` |
| Previous pool: RelayerRegistry | `0x4925f9771d0ca1f89bd45100ab92a398857c8d0d` |
| Previous pool: RootBounty | `0x0ef6c71a9542ce086d598d946c5c27ad6fecff90` |
| Previous pool: ShieldFeeRouter | `0xebe49155459833d865737ca1288122a354f11df6` |
| Launch: adapter | `0xf64c399696e10c84c73b66350b45ba0fcd860927` |
| Launch: verifier | `0x59aa962433060d0206c3595afeb1793c621747ea` |
| Launch: evaluator | `0x619a5ecdee779ec4455bbfa2ec3a5f4f9dee3ff6` |
| Launch: evaluator image data | `0xd495809981624e9c74d5c4cabf83160f1013b3d9` |
| Launch: Poseidon hasher | `0x0096416e4385bbd459141140a542f30e05b1a4d7` |
| Launch: AssociationSetRegistry | `0x4375ee7d015ac8e404a03deb577e90b08de32df3` |
| Launch: settler | `0xc973cad63834cff7ab426f18c11d113c3898031c` |
| Launch: earlier settlers | `0xb16ffe4827abbaeab8adb53b3faeb14b15fb5fea`, `0xc6424447e96381bf023d0adcdf85e70ccb17af67` |
| Launch: relayer | `0xb6eb6aefad95152c0d4f5ff4552915cb27548a6f` |
| Faucet signer | `0x74e13f14f4d1f28ac4c2ff0344ebdfc3253e7a57` |
| Safe owners (2 of 3) | `0x9b917d43ef99c8a440bba268c632c1092c744877`, `0x5d9489ee17c1b960e8feea482528ba4eb9cd631b`, `0x7098c4b08a190ff36da1f6bfe57898f9e0a365de` |
