# Deployed names

Some verifier contracts were deployed under the names they had at the time, and their published source
carries those names. The source in this repository uses plainer names. The code is the same; only the contract and file
names changed. To reproduce a deployed contract's bytecode byte for byte, compile it under its deployed
name, because the name is part of the compiler's metadata.

## The production pool

| Address | Deployed as | Source name |
|---|---|---|
| `0xDA9dD4A3e957AFD2179131273C93dabBA1186A44` | `ComposedStarkVerifierV2Shapes` | `ComposedStarkVerifierShapes` |
| `0x112aA1E495B7e1361e102f71c5190f72E5b734D2` | `NbStraightEvaluatorAt` | `NbStraightEvaluatorAt` |
| `0xb675b1f38fd6bc37b2792f7675faa830291306c6`, `0x2ea3dec8a79a8110f5bbc3ca304911eb7f17cdd3`, `0x2e1edbb148d6a2129e2b9b1f8f4562d2c4e91960` | `PrepareNb_A`, `PrepareNb_Ap`, `PrepareNb_B` | unchanged |
| `0x1f0b4700f4c5d62cd7b48b116d6effaaa09af0a5`, `0x1f24694d8cd4697b6aada1ad9dcdfc56d9a335b3`, `0xebe29d5b0b7a61abf422cfe322df6ff7b5b37c24` | `WalkNb_A`, `WalkNb_Ap`, `WalkNb_B` | unchanged |

Every other production contract (`ShieldedPool`, `AmountPolicy`, `ShieldFeeRouter`, `RootBounty`) was
deployed under its source name. [Deployments](deployments.md#source-verification) lists the Sourcify
result of each.

## The previous pool

| Address | Deployed as | Source name |
|---|---|---|
| `0xde6110142b39730f480f9d66c408f150a7e823c1` | `ComposedStarkVerifierV2Shapes` | `ComposedStarkVerifierShapes` |
| `0x8f9efa664cb76afca63e92639f3706a5dfa46975` | `V2StraightEvaluatorAt` | `ShapesStraightEvaluatorAt` |
| `0x345ba9bd573c86f6aef27b9bfabc4109d11e4c17`, `0xe6e41d2eba77450af489933438586d71c8637f28`, `0x19f3b963f861232aef86558e81059f0f7bd85b0f` | `PrepareV2_A`, `PrepareV2_Ap`, `PrepareV2_B` | `PrepareShapes_A`, `PrepareShapes_Ap`, `PrepareShapes_B` |
| `0xd9f7bcc49bfdab364324c6e9f769ed0484eb78a6`, `0xcf41ea6702f9c2af1cedfe8a0cb6ae4cb14ba756`, `0x1e237dc5ecaa03c88a447a6384ae88149a701841` | `WalkV2_A`, `WalkV2_Ap`, `WalkV2_B` | `WalkShapes_A`, `WalkShapes_Ap`, `WalkShapes_B` |

The deployment scripts and directories were renamed the same way: `script/shield/DeployShapes.s.sol`
deployed the previous pool, `script/shield/DeployNotBefore.s.sol` the production pool,
`script/shield/SplitFormat7.sol` cuts a format 7 body into its three chunks, and `spec/shapes` and
`spec/not-before` hold each pool's pinned proofs and evaluator image.
