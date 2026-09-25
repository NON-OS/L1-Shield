# Deployments and receipts

Every contract of the launch stack on Sepolia (chain id 11155111), and every transaction that a
figure in these documents rests on: tx hash, block and gasUsed, with the state each contract
reports today. It is for anyone who checks a number against the chain. Each row can be checked
with `cast receipt` or `cast call`, as the last section shows. What is checked and what is not is
in [20-security-status.md](20-security-status.md).

## Contents

- [The launch stack](#the-launch-stack)
- [State read on chain](#state-read-on-chain)
- [Configuration](#configuration)
- [Roots](#roots)
- [Settlements](#settlements)
- [Deposits](#deposits)
- [Verifier walks compared in 18](#verifier-walks-compared-in-18)
- [Reproducing a row](#reproducing-a-row)

## The launch stack

All deployments are sent by `0x6b02855B93F946643cbE1b499308645b59423188`, and every receipt has
status 1. The last five rows are the broadcast of `script/shield/DeployLaunch.s.sol`.

| contract | address | deploy transaction | block | gasUsed |
|---|---|---|---:|---:|
| `PoseidonGoldilocks`, the tree hasher | `0x0096416e4385BBd459141140A542f30E05b1A4d7` | `0x1e0e711d240914bbff36344464fcbc8c724a6342545fab65a28f37cc4d5e1934` | 11,758,283 | 1,921,383 |
| `AssociationSetRegistry` | `0x4375eE7D015aC8E404A03deb577E90b08de32Df3` | `0xaec42a52d65476285db166326e8357bf45afc5b595d3a934ce4d20c6c8edf68f` | 11,761,496 | 220,074 |
| `NoxShieldStaking` | `0x739e06586305c4a543d5cFd5fE5506aA289cf397` | `0x6367e32ef2c9fbecf966ca049ff85ebb49a9bae9331e990fd727c09abcf1747c` | 11,761,497 | 1,162,012 |
| `ShieldFeeRouter` | `0xEBE49155459833d865737cA1288122a354f11df6` | `0xb2aa22b3a5aae7efa928c002087d670f0d2076ee20de99e9d303f42491aff980` | 11,761,499 | 1,848,604 |
| `RealSplitVerifier` | `0x59AA962433060D0206C3595afEb1793c621747eA` | `0x52c0f9f221ce91b189baafa5e39fa889e490924842eeb89ac22758176f0e6f07` | 11,772,146 | 4,523,512 |
| `LaunchEvaluator` | `0x619A5ecdEe779Ec4455bbFa2eC3a5f4f9DEE3FF6` | `0x650ebb51a1720fe77ef93601da7dcb2d695c0253f7d71a20663569a0b89b3462` | 11,772,147 | 5,687,769 |
| `ComposedStarkVerifier`, the adapter | `0xf64c399696E10C84C73B66350b45bA0fCD860927` | `0x2c833bbdeb8748658a668beb98c33bf2338e2a12ac05391548bb557705482553` | 11,772,149 | 1,380,943 |
| `attest` of the honest launch proof | | `0xa6ffb574c26b8203f473569e6e3497ef6256fd34839a8cdb54cd7ec3c2254b99` | 11,772,150 | 6,748,211 |
| `ShieldedPool` | `0x8e377752C8890E23A1E9F40eBbD41183Fc6949e2` | `0xdb96b038e83b4bd17534819f9600a431700dc77afceb8f878119963983b87c42` | 11,772,152 | 11,664,986 |

The `attest` receipt emits `Attested` with digest
`0x80914f72ee64e9771b4b8a638365f5f8b7b896400e5d917cf00515c00cd21c30`, the 32-byte self-test proof
the pool constructor verified. The pool deploy receipt emits `OwnershipTransferred` to the Safe,
`RootUpdated` for the empty root and `AssetRegistered` for asset 0, the native coin, at scale 1.

## State read on chain

Read with `cast call` against a public Sepolia RPC.

| contract | call | value |
|---|---|---|
| pool | `verifier()` | `0xf64c399696E10C84C73B66350b45bA0fCD860927` |
| pool | `treeHasher()` | `0x0096416e4385BBd459141140A542f30E05b1A4d7` |
| pool | `associationRegistry()` | `0x4375eE7D015aC8E404A03deb577E90b08de32Df3` |
| pool | `feeRouter()` | `0xEBE49155459833d865737cA1288122a354f11df6` |
| pool | `owner()` | `0xD4251BA8bD4F68690BaB9f27d544819cFBE11854`, the Safe |
| pool | `wordsPerIntent()` | 12 |
| pool | `betaMode()`, `openDeposits()` | false, true |
| pool | `settler()` | `0x0000000000000000000000000000000000000000` |
| pool | `shieldFeeBps()`, `unshieldFeeBps()` | 25, 25 |
| pool | `scale(0)`, `scale(1)` | 1, 1,000,000,000 |
| pool | `maxRelayFee(0)`, `maxRelayFee(1)` | 1,000,000,000,000,000 and 10,000,000,000 note units |
| pool | `nextLeafIndex()` | 171 |
| pool | EIP-1967 implementation slot | empty |
| adapter | `soundnessBits()` | (142, 80) |
| adapter | `soundnessTermsForSize(1)` | (80,774,533, 81,933,909), millionths of a bit |
| adapter | `evaluator()`, `wordsPerIntent()`, `settler()` | `0x619A5ecd…3FF6`, 12, zero address |
| verifier | `nq`, `logDomain`, `logTraceLen`, `traceWidth`, `nCoeffs` | 19, 23, 13, 44, 100 |
| verifier | `grindBits`, `finalSearches`, `roundGrindBits` | 25, 8, 20 |
| verifier | `cosetShift`, `nPeriodic`, `nChal`, `regionWidth`, `maskColumn` | 7, 93, 2, 34, 42 |
| verifier | `digestBytes`, `friRadix`, `logDegreeBound`, `logFinal` | 24, 4, 17, 9 |
| verifier | `periodicRoot()` | `0xbb7614937ae6d7e5e26e88610fae8ff9e5195fef4721fdbd0000000000000000` |
| verifier | `recomputesCompZ()` | true |
| evaluator | `image()` | one data contract `0xd495809981624e9c74D5c4cAbF83160f1013B3d9` with 21,306 image bytes behind a `STOP` byte (`cast codesize` 21,307), no second |

## Configuration

Owner calls go from `0x6b02…3188` to the Safe `0xD4251BA8…1854`, which calls the pool.

| call | transaction | block | gasUsed |
|---|---|---:|---:|
| `registerAsset(0x3E5249A6…5d36, 1e9)`, asset 1 | `0x25f3f01ac8a1d9a779e7526eb5d38652a55da2c7b5164051e5f5fedd2c3a9450` | 11,772,253 | 139,013 |
| `setBetaCaps(0, 1e18, 1e20)` | `0x5ad5033a93de6af3ac16812c7c5cd5a490b179774845c1a7205df28afbe2200a` | 11,772,255 | 112,996 |
| `setBetaCaps(1, 1e24, 1e26)` | `0x24dfffd42c08782184d9f97a910e81b19c2138589db316d9e56a2be422cd2c11` | 11,772,256 | 113,032 |
| `setMaxRelayFee(0, 1e15)` | `0x11197557485cc911e98df343fac79feffd6ca272eeb3984afe3bfa3743a00f92` | 11,772,258 | 90,365 |
| `setMaxRelayFee(1, 1e10)` | `0x1cbad1787ba0c33d3560b975dbfa7348b57bc3cf8d9cb251c1cc7aecb1a4c338` | 11,772,259 | 90,377 |
| `setOpenDeposits(true)` | `0x47081faafe17fa03bb2bba936a9e3d977ea4fd9ab0c70cd5fc040f647c414cdb` | 11,772,261 | 68,139 |
| `setBetaCaps(0, 5e18, 1e20)` | `0x3073883263c3f0ae6e11f6619f1aba8d645fc129335e8def205038d0616d3236` | 11,772,394 | 75,996 |
| **`endBetaMode()`** | `0xcbd9542ec16f00ce7b1e3777066e7f62716ab77d2299619a240b553deb29c9d5` | 11,775,568 | 69,752 |

The arguments are read from the events each receipt carries: `AssetRegistered`, `BetaCapsSet`,
`MaxRelayFeeSet`, `OpenDepositsSet` and `BetaModeEnded`. Since `endBetaMode` the allowlist, the
caps and `betaRefund` do not apply.

## Roots

### `commitRoot`

| transaction | block | gasUsed | leaves covered | sender |
|---|---:|---:|---:|---|
| `0x1788bdff125f9bf8d0e4df5b2a9453187d7593f10aff5e68dc8811dff5b63fd9` | 11,772,298 | 4,424,015 | 2 | `0x6b02…3188` |
| `0xc34b2b08186eb23db1eb1872b3a540ddd9635ba5b4a413684c1f4445b8a00520` | 11,772,497 | 4,406,893 | 44 | `0x6b02…3188` |
| `0x8ca2006e6985e3ddc7dd4642a90d99164482bdd9c2f678e78ab7bc645a28c7cc` | 11,772,853 | 4,408,882 | 113 | `0x6b02…3188` |
| `0xd80244d8d4c6e4f00f4edce64d6e0a75421d97e5d5514b1155bde387b8a16383` | 11,773,436 | 4,408,882 | 165 | `0x6b02…3188` |
| `0xfdaa692284686f062f0df6953b3bc826774c7e265ebfa5cd43464d5c8f663f00` | 11,774,990 | 4,408,871 | 167 | `0x6b02…3188` |
| `0xc24f08de1d0b609c322c4e4ff9cac057bd483d6e488ccd7e70798104f9a83f65` | 11,775,614 | 4,408,882 | 169 | `0xb6eb…8a6f` |
| `0x61eb221e9126fe7ec895788b478dc3785b4d46bee823626309a712a95f09f4bb` | 11,775,651 | 4,408,871 | 171 | `0xb6eb…8a6f` |

The leaf count is the second field of `RootCommitted`. `0xB6eB…8A6F` is the relayer.

### Association roots

`AssociationSetRegistry.publishRoot` calls since the pool was deployed, set ids 7 to 14 in
`AssociationSetPublished`.

| set id | transaction | block | gasUsed |
|---:|---|---:|---:|
| 7 | `0xff98a24fa97d70f437fa436282489c1827f819e89d8e5652638bb42c125ec6cf` | 11,772,299 | 75,244 |
| 8 | `0xfb0667fc017a1bcb275f46214835ffeccf6a0a36dc98d5811473332752cf1d08` | 11,772,498 | 75,280 |
| 9 | `0xb2de7382c3bfb76c68108c61e8629cfe1ff7134f5ea7ca80a675ee069f9e0dae` | 11,772,854 | 75,280 |
| 10 | `0x79b295b270048f34af35baaa1ebceaa4be9fa309c0324ef8fab4f8c59a283c31` | 11,773,437 | 75,280 |
| 11 | `0xfc4b7bf5127d6cdd6294b469ae4d225fe5fda44f9eef0c078184f0ab9b9d1484` | 11,774,991 | 75,280 |
| 12 | `0x7f2324cbcefbe62164c2f0494b90cb735526abb6521fa4e7a374f48763594e25` | 11,775,142 | 55,380 |
| 13 | `0x96070923944440ac42652c935cd6c85aedfd25b881140f334283c2feda2dfbd8` | 11,775,615 | 75,160 |
| 14 | `0xeebe018f62ad056682bc0515f9dd0a684d32f41fe6fe5991e58e5f9f6ca3c525` | 11,775,653 | 75,160 |

## Settlements

All 43 `settleBatch` transactions on the launch pool, in chain order, each with status 1 and
116,708 bytes of calldata. Rows 2 to 41 are batches 1 and 2 of the
[launch record](https://nonos.software/assets/papers/private-transfers/private-transfers.pdf),
appendix B. The output leaves are the `leafIndex` of the two `NoteCommitted` events.

| # | transaction | block | gasUsed | output leaves | note |
|---:|---|---:|---:|---|---|
| 1 | `0xe622a8310a7321f4b743ae9e4c745cb5bc824abdea1590e5f9eb845d11f5484e` | 11,772,324 | 7,241,302 | 2, 3 | first launch transfer |
| 2 | `0xc8a4fa222a5bc315a34a3148820a93c78cb8a96695987ab625f9e1fba8bcd5c5` | 11,772,663 | 7,075,429 | 44, 45 | batch 1 |
| 3 | `0x55e5f408f4b5df694280d97b9f92bac3440755402aec7b5f56d47f3b5cc41e04` | 11,772,678 | 7,477,858 | 46, 47 | batch 1 |
| 4 | `0xdb770d40243cedd32fbb371a632d74c8f49e9fe452bcdf17597579b13714c548` | 11,772,686 | 7,071,240 | 48, 49 | batch 1 |
| 5 | `0xcadc1cbdcecd9728b8719228c2a20e6d2d314a58601b35c429d38832c389ff86` | 11,772,699 | 7,241,481 | 50, 51 | batch 1 |
| 6 | `0x3b3d9b887ab5e5f08f7ccdc5138fd906d39249964e804748d5eb917a8fbbebc6` | 11,772,707 | 7,071,917 | 52, 53 | batch 1 |
| 7 | `0x5404431b202b9ada9f6fbe55d9df6ff3f9f2174e07fce14123a8817a74a3930b` | 11,772,722 | 7,341,478 | 54, 55 | batch 1 |
| 8 | `0x2d5a8bfc16fa65442a8f53325c1e7726f0cb57d2ed719714de04fef27fbf50a0` | 11,772,735 | 7,069,380 | 56, 57 | batch 1 |
| 9 | `0xe01ece8a85d2c550569e030e6620e2890995e03e3ee9edcfa8b263a99b9635ba` | 11,772,747 | 7,203,510 | 58, 59 | batch 1 |
| 10 | `0x4a8d6f191540cff620ea435fbf7f3574a0d2094ffa6ee012e4954cceffc1e207` | 11,772,761 | 7,068,624 | 60, 61 | batch 1 |
| 11 | `0x94841d36dbded3cb4d00d7ebc35e99e96e115c23153e8168efe11fbb658386f8` | 11,772,780 | 7,744,702 | 62, 63 | batch 1 |
| 12 | `0x379821b8f99793a6655f54dd2462315fcf0162d94372d02fbe3b6ed17b33b24e` | 11,772,792 | 7,207,727 | 67, 68 | batch 1 |
| 13 | `0xdddc13f678ef18965219a5d971c1f5c5ba2749aab497307a365be4324ecfce3b` | 11,772,800 | 7,204,920 | 75, 76 | batch 1 |
| 14 | `0x29d3dd79e0ae68711e920699ba2c54c46d9c57d7bb0af327745eb7ed222c85ef` | 11,772,831 | 7,207,661 | 91, 92 | batch 1 |
| 15 | `0xccebd6e5953970ff7959fe7cf2fea85e62c2c466d7e0388d24b8a5886b4f5824` | 11,772,843 | 7,610,180 | 95, 96 | batch 1 |
| 16 | `0xd7c801fa38df26d7479f7852ddd6f3012cac185f4e95ffd38b0cae31b7c4895a` | 11,772,863 | 7,070,339 | 113, 114 | batch 1 |
| 17 | `0x8c283cda61f7c8518d519963873a7674eb3d989d440cafc0a788cebd3cd20d81` | 11,772,880 | 7,204,378 | 115, 116 | batch 1 |
| 18 | `0x507a0e165fe0ed07581178b18199aebc0e935ea2a6ad34d918e25102fd65b72a` | 11,772,900 | 7,071,047 | 117, 118 | batch 1 |
| 19 | `0xeea0489ba07f884a937defad441a7a3f0a6668c56180d65970e715348519a066` | 11,772,932 | 7,340,505 | 119, 120 | batch 1 |
| 20 | `0xaa801a3dc0e50686893505ddc33024f6ded89e342a8145214022270217edbf39` | 11,773,001 | 7,066,977 | 121, 122 | batch 1 |
| 21 | `0x31da2f00aee361814632f3a018d66aa43543627b9710691df3cc7e842f11b77a` | 11,773,017 | 7,207,147 | 123, 124 | batch 1 |
| 22 | `0xdaf8cae45b93ae7afe601e676a1d9198833c5ffe6e3b2bd003a0fe65142adec7` | 11,773,026 | 7,073,736 | 125, 126 | batch 2 |
| 23 | `0x105e4e2574841229cfddb0d644a672f41f17ffb56bf79b43dab40ddc59cd5e06` | 11,773,030 | 7,882,382 | 127, 128 | batch 2 |
| 24 | `0xcd41a1c34c295ae75f7d110e732604a0c877c90d2073057a9f1e471f7e60594e` | 11,773,033 | 7,067,292 | 129, 130 | batch 2 |
| 25 | `0x920e4df05263a177301a3e285ff98dc47ce70b90b6b4f803294e7c78139cb6ab` | 11,773,038 | 7,204,130 | 131, 132 | batch 2 |
| 26 | `0x20507b9d6f971579fd42accdc73d8818a26389fa0a19b1132ae7d02aaa0b27e6` | 11,773,042 | 7,074,963 | 133, 134 | batch 2 |
| 27 | `0xf230c2063f4a375f9fa6afc9c76106ceb6fbc7049cfceec7781bab64fa009b30` | 11,773,044 | 7,339,836 | 135, 136 | batch 2 |
| 28 | `0xddae43dc4a7075fbd926620daa67f038f25d649e80fa1e10a5c64062c2f90db5` | 11,773,047 | 7,073,700 | 137, 138 | batch 2 |
| 29 | `0xf5c4b570d553f7db9bd0b8b55bccc3ccaa16669ef39210de49c92a9825c4cc3c` | 11,773,051 | 7,207,786 | 139, 140 | batch 2 |
| 30 | `0x0573b21a7875e0fb824d9a90acb6b10baffa9e259b6a0a579bcf89d789c2345f` | 11,773,057 | 7,071,302 | 141, 142 | batch 2 |
| 31 | `0x15fc3ea80c28ae1eac484d51b3d85253a748e225ff3a170f9454eaed4fd6993c` | 11,773,061 | 7,479,249 | 143, 144 | batch 2 |
| 32 | `0x5f4ddacf00966a1c0d10dd055d2d32c0000fe9fafb926094be6064a37d7f0d22` | 11,773,065 | 7,070,848 | 145, 146 | batch 2 |
| 33 | `0xeed0f11bc85692d0b30b5418f46a8fb1cc930c4758cf0a67d0ff094b8e0d173f` | 11,773,069 | 7,205,741 | 147, 148 | batch 2 |
| 34 | `0x1a42c442fa6ccde457b3ba8c2196a9239087b93b770556c877c810846ba3db34` | 11,773,074 | 7,073,581 | 149, 150 | batch 2 |
| 35 | `0xbdbd9847e7f9aab62784480abbab48db68b93cbda95896d0f0c4e65d71c15764` | 11,773,079 | 7,342,374 | 151, 152 | batch 2 |
| 36 | `0x7791d3922be795ba91c1f6f09709586e189cc164a13b49eea6776463a4be604c` | 11,773,085 | 7,071,813 | 153, 154 | batch 2 |
| 37 | `0x7fdc5de15c8019454ff7ef6d0437510be1991911d0241ed1e3ad82943e08ecc5` | 11,773,089 | 7,207,281 | 155, 156 | batch 2 |
| 38 | `0x2ff44c3673ed82ee976d9d87dae0044b1f2ecabffb0172e5a7127e138c5525de` | 11,773,094 | 7,072,260 | 157, 158 | batch 2 |
| 39 | `0xb3aff4a978382cefbb88ca756c6dcb4042bbd6402972b7a1ab58b1adcad7c10f` | 11,773,096 | 7,611,241 | 159, 160 | batch 2 |
| 40 | `0x132d3a3ad6adad120d1e3f27293850acd2fd9c5350e7c34499dd4bb172ed4406` | 11,773,100 | 7,074,383 | 161, 162 | batch 2 |
| 41 | `0x130e85717fdd3e8502a4e4f0dc5f75b8da984f5a3503f15fe4dc98029354668a` | 11,773,102 | 7,209,811 | 163, 164 | batch 2 |
| 42 | `0x1efa772d78a8ba014b51a1d28c46020b0df446427af3c4db9928559d683d8fa8` | 11,775,200 | 7,337,580 | 167, 168 | gas split in 12 |
| 43 | `0xbed088f0b842c8416a269d37bfb7342649d91a4260e1d6b73a7b3a51383ad04f` | 11,775,650 | 7,086,413 | 169, 170 | relayer `0xB6eB…8A6F` |

Rows 1 to 42 are sent by `0xc973CaD63834CFf7ab426F18C11D113C3898031c`. Row 43 is sent by
`0xB6eB6AEfAD95152C0D4F5ff4552915cB27548A6F`, the automatic relayer. Row 42 is the settlement split
in [12-gas.md](12-gas.md#where-the-gas-of-one-settlement-goes). An `eth_call` of `verifyBatch` on
the adapter, with the proof and words from the calldata of each row, returns true for all 43.

## Deposits

Every `absorb` on the launch pool, 85 transactions, by leaf index. Asset 0 is the native coin and
asset 1 the testnet NOX token `0x3E5249A65CA513D5e11260222e0D26f46b465d36`. The 80 deposits of
batches 1 and 2 of the launch record are every row below except leaves 0, 1, 74, 165 and 166.
Gas by leaf is grouped in [12-gas.md](12-gas.md#deposits).

<details>
<summary>85 deposits</summary>

| leaf | transaction | block | asset | gasUsed |
|---:|---|---:|---:|---:|
| 0 | `0xc17a8b58c820cf64b628d3e28143ed1c8b2b9186d69164b3e72e4158bded88ff` | 11,772,293 | 0 | 349,190 |
| 1 | `0x162b5b0111db6ddac5e831af4eb94e9e2785f985c6ca58496cb5d23cce2cb119` | 11,772,295 | 0 | 364,542 |
| 4 | `0x0cf5c334d215a3c1e8aae97203c5d1d197e1dd8c598f9a96582fe623d6b6e636` | 11,772,429 | 0 | 263,690 |
| 5 | `0x89dc693d6b2a96c6a03c5f0bd1be2087a678768cf0d017918ecad61c9650086e` | 11,772,430 | 0 | 364,554 |
| 6 | `0xa67ee46b5862d5791701908d3bb7e2ff935e427709c92b88fa62465c9ff51841` | 11,772,432 | 0 | 263,690 |
| 7 | `0x9a8b5441cf706db2534e1b46cc5e923387a2f2a73a856833ca12005c4fba5f1e` | 11,772,433 | 0 | 634,682 |
| 8 | `0x9cd274610097f356c9ba88f22a7e7f392b723f455add2736e0f50f2527142218` | 11,772,435 | 0 | 263,690 |
| 9 | `0x46acd11a1558b0849f1313ad056c99d88abae8fbfdb4732a38f00daed78f8b96` | 11,772,436 | 0 | 364,554 |
| 10 | `0x705aedb98f3cfecae33af7e811c4a7d6e84c56a1c59fa71e7be83e01c7ddb281` | 11,772,437 | 0 | 263,690 |
| 11 | `0xf0ad89004997b7aab8d0b4b2dc601e1c2186fbacbfb247bca908db81c3fe47a0` | 11,772,438 | 0 | 499,618 |
| 12 | `0x08ddbc68e34cc1cc3284d91b92ec74551f11de6eb17881a1f39e61abf4eba565` | 11,772,440 | 0 | 263,690 |
| 13 | `0xe70ff5ac2dd723d83224528068918defbf7ad75ff9d95304681758495010fe1e` | 11,772,441 | 0 | 364,554 |
| 14 | `0xc2d2b7feb04d81c8158d7a38436278f1176bade5d16d7c73de6edbd695abbc6c` | 11,772,442 | 0 | 263,690 |
| 15 | `0xddd64bbb862c6eb4ccbfd82ee6f6d91949ea7c792dff6e45a4f3026ea951522f` | 11,772,444 | 0 | 769,746 |
| 16 | `0x855212d5f1c62255310593a788c2ee6d25d1870e74664901bc65f22bc593a6f2` | 11,772,445 | 0 | 263,690 |
| 17 | `0x4a6c8debbec4efd615f168e18c11278ecee76b37c84b64c52c92c8919069ca85` | 11,772,447 | 0 | 364,542 |
| 18 | `0x5d4614ebdb7f77a7e87a9f9886004b48fb36a033d3bb75c4689eb4123cac189f` | 11,772,448 | 0 | 263,690 |
| 19 | `0xb13a4261c60f6f5d2d0f9eaea139a3e3dff93ee359be1380a13c08f725bda632` | 11,772,450 | 0 | 499,618 |
| 20 | `0x64b403acc4d220dc9f766e7bb363ee3252c35a853e295eaa5b8355f15210f90a` | 11,772,451 | 0 | 263,690 |
| 21 | `0x45ab7d7a56fcb72b7bd8d6903fc3eb7351914535fa638f25621ac14b8cbf1f30` | 11,772,453 | 0 | 364,554 |
| 22 | `0x6943d9bab2fa398074dece1d5adadc5563f1cc740685cb22b2fafa3ae73a48e1` | 11,772,455 | 0 | 263,690 |
| 23 | `0xbdfbbafd6d303e219f51983c0e1963065b674391c5625374eb1bca594118d96f` | 11,772,456 | 0 | 634,682 |
| 24 | `0xeb794320489e1f877142db087518a932ba4ac6385126df73e8b780c52ac66a73` | 11,772,458 | 1 | 395,527 |
| 25 | `0x47a4a5fb9898e00e92b01201b9daa5ae89b23e0d4c9ea6efd4adb1941c710103` | 11,772,460 | 1 | 418,391 |
| 26 | `0x6631e17b74c2e05be7f2a3bb6844e8517a2c8538a08e2b2337634fe871929ef1` | 11,772,463 | 1 | 327,127 |
| 27 | `0x526e573b73e1f0183669cfc1fac6f6c30ac0b8edca897f832f7072d5eb5230be` | 11,772,464 | 1 | 553,455 |
| 28 | `0x51a36e35aa28b3fafc47e74da998a4ff97cf113c2ee6bd52c9fe265d9b775cbb` | 11,772,466 | 1 | 327,115 |
| 29 | `0xf5e40bad0ef7c2cd6dac440f0d4b646414ec4a0f358dbf9e57ac268295cdec88` | 11,772,467 | 1 | 418,391 |
| 30 | `0x8d9b2e9befc78ac796e08d470f0185ef94728495b46c74d2d77a29e75194e790` | 11,772,469 | 1 | 327,127 |
| 31 | `0xa98f5bf3f26d8551a0d0b451f4f99262862376b2535e50f7ba54bb37e101aac3` | 11,772,471 | 1 | 958,623 |
| 32 | `0x7a666f4aff1190755d7b4fea4b4c02c4d5ceece8fcca2a864dcf8d47eb907361` | 11,772,474 | 1 | 327,127 |
| 33 | `0x54c49b0c3e78f321a564ed0f91e87c72ab4508720695f78a6690e4641c8759ab` | 11,772,476 | 1 | 418,391 |
| 34 | `0x7e871e1aad2d309b4e63d1e204b4d278758875fe96ce34e95e77c2e83871833a` | 11,772,479 | 1 | 327,127 |
| 35 | `0x322c4c4b51931c3116091c9f2c1cb9f8e5cfb626dca293abdca9f2a4006e53ac` | 11,772,480 | 1 | 553,455 |
| 36 | `0xd805c1bf57e5302264d36de63f3325b8981ff6b518a8606e61af493c3ecb0173` | 11,772,483 | 1 | 327,127 |
| 37 | `0x2b732a060882ad8b0588c1d7dcf08775f62df293d6802224053b5025fd2992f1` | 11,772,484 | 1 | 418,391 |
| 38 | `0x216a9b0b2fe1cebc98fc51231184ef1615775fa75c06dea1b6f11de52e6ba8a3` | 11,772,486 | 1 | 327,127 |
| 39 | `0xb05e4c50b4eeec7ca1c8a36edc9233e3839e1bb4374fd40250d22d18156ff34d` | 11,772,488 | 1 | 688,519 |
| 40 | `0x51cc3a55abea357c0b68f72a864fe6b489f7114c06b340def5f022a0761fa5d0` | 11,772,490 | 1 | 327,115 |
| 41 | `0xd9f0d444a2ba91bb525ee336c163f4089d867259e5237b9bea34e3645b7c15d8` | 11,772,492 | 1 | 418,391 |
| 42 | `0xa2a6fcd007fdb88fe93e2d0dfa4773054615e1cff5eef025ccdd59f8f3a8ccdd` | 11,772,494 | 1 | 327,127 |
| 43 | `0xed000c619866d53e16a3b58a668cad6fb896f0bced0da2a15aa68b6065771911` | 11,772,495 | 1 | 553,455 |
| 64 | `0x9c792fe2fe980055691ac61f74fad5eeefd6055216f41e326e8f5a3965e7992a` | 11,772,789 | 0 | 263,678 |
| 65 | `0x5d69bdcea99744d9f48cf56705202551a3fd494b28bd28ee7cb95ba73cc94857` | 11,772,790 | 0 | 364,554 |
| 66 | `0x74b458b5658e3efb3042d2b9248b339b5b51f9f4833b2259a1a45efe3f354fb1` | 11,772,792 | 0 | 263,690 |
| 69 | `0x15b21b14c67360db44baec15b8abb56589ef249a26b59869b71c6a4102159203` | 11,772,793 | 0 | 364,554 |
| 70 | `0xa5f8aef4237ee2dbaa5f5ead8e93ccbb319b372fa13d3004640d862af3799f30` | 11,772,794 | 0 | 263,690 |
| 71 | `0xbac80b0ea46e0d2dd0a03c653caf3303d5cda4869dd8eb3500c6eddb0baf0766` | 11,772,795 | 0 | 634,682 |
| 72 | `0xc982eb342f33b92a141d979fea2a708fde914374330da316046b503368953da6` | 11,772,797 | 0 | 263,690 |
| 73 | `0x7123643e69f3b239785b7a3237141a9f66b23797bea9a79f61483203b4bcc262` | 11,772,798 | 0 | 364,554 |
| 74 | `0x3f560e5a7d1f099bedc9c21f2fbf354570765b720876891ac97076e3d00e5e87` | 11,772,799 | 0 | 263,690 |
| 77 | `0xa943d6d4349f9a896283692146b3ee85949dd4d05e979c232311790b1bfdb1d7` | 11,772,803 | 0 | 398,754 |
| 78 | `0x419637894553708858e307b8b29fe3994149dd3135b21077577089277269a02a` | 11,772,803 | 0 | 263,690 |
| 79 | `0xb65c12523740eb453ea647c5cb46ef5f6cba4d5948493107b1c953378bae2de8` | 11,772,810 | 0 | 769,746 |
| 80 | `0xfc9a350e379bffefa317eb0a6147f6a26bec46225d4fe3f8cb5d184ec7fe9853` | 11,772,810 | 0 | 263,690 |
| 81 | `0x036d4eb54af32519c680d1fd58d871f57ef21407e91c39166749fa38a7fbe0c0` | 11,772,810 | 0 | 398,754 |
| 82 | `0x56b4dc4cf953b7ab7542d69788d36ba3b5221152acbf3b2c54d0ebd8a8231d87` | 11,772,810 | 0 | 263,690 |
| 83 | `0xb99c772a25e5862012024a975216bc79063b452763cf4ad01ef0cc2ded4a4147` | 11,772,810 | 0 | 499,618 |
| 84 | `0x91cbac4547e186d662d267721b574a2a19fb4c5c25000c96e9c0f60eec16b0f6` | 11,772,810 | 0 | 229,490 |
| 85 | `0xa501bb83599bd3e58a1ca9afa7156d8014f06c7a19de9a00ce363fb6ec90f089` | 11,772,812 | 0 | 364,554 |
| 86 | `0xc4544ac981390ff04451e8625478298e20e07a559d6a5da54b62875caef46394` | 11,772,812 | 0 | 229,490 |
| 87 | `0x3daf7eda590428658826df3d899e0a07d616abd5b85293cb4354152e3c0a280e` | 11,772,813 | 1 | 732,319 |
| 88 | `0xf87cc3447a4cce8a85df58735a35957d1f29690c84ef46145a7dc38c1e3acebc` | 11,772,813 | 1 | 327,127 |
| 89 | `0x6f885f534d3bcd78064cac161b91e72345f3ec14f48e0cabb79c37b62a8dad3d` | 11,772,814 | 1 | 418,391 |
| 90 | `0x510a299976dd8ae5bba47c5edd517c04afd436557df8900188a4a7d532dffbbd` | 11,772,814 | 1 | 283,327 |
| 93 | `0x065d5a1b230059bebb4b6531dcfa63655e83c64f6588fc14769213b56b0c4ec2` | 11,772,843 | 0 | 364,554 |
| 94 | `0x9703dcad3f07200024ba21b7e40c73fbaa788c6abf897ed317aa89f41dfc447d` | 11,772,843 | 1 | 327,127 |
| 97 | `0xd0ca4551a0ba04683409395a66930a15e7c8c88debd8285f0afc6ad45565d047` | 11,772,844 | 1 | 418,391 |
| 98 | `0x2b38bc40ad63ac0175e8e02c8b567389168df4a4a6bc9858ef0b780972062d28` | 11,772,849 | 0 | 263,690 |
| 99 | `0x21664548408cc48d43c7b9aa8772cd19e673229d2a01d8d252374f841b396d00` | 11,772,849 | 1 | 597,255 |
| 100 | `0x49a556d167b0de3a5c1f0a3ac4ff16707579517d456f5a58e70a89ae6178e957` | 11,772,849 | 1 | 327,127 |
| 101 | `0xdc89d985a274f0bacd99efc8ab6d256543afc376af16d9be592489e930b755ff` | 11,772,849 | 1 | 462,191 |
| 102 | `0x686496b265e8530a3b3330410901f293b0c9198f8ae64419a67300e12181ff64` | 11,772,849 | 1 | 327,127 |
| 103 | `0x5d01ec40fcb6ece5dfff609fee5ab8d371f25db823cd797042011be3b3870739` | 11,772,849 | 1 | 732,319 |
| 104 | `0xe7b4b786066b0d83c83b26537655ec74a5129b740628917f1dd294e3ce2e1814` | 11,772,849 | 1 | 327,127 |
| 105 | `0xcb9bb47dad3970090e22ee998427b5471d83831d5162c3001105c397d75d05ca` | 11,772,849 | 1 | 462,191 |
| 106 | `0xf0436dc78d3606426905ef7f59d015cf1e8d7f8375be5fef2cc33f2439877f6f` | 11,772,850 | 1 | 283,327 |
| 107 | `0xdd2ab7f3b7d6cf18aa30de509db59427a4d065d1a68df3e796ce7194419582f7` | 11,772,850 | 1 | 553,455 |
| 108 | `0xa6b068f15efc45d27511fd34fef2a0b268aea5dd648285227064e77c6f1fbfdc` | 11,772,850 | 1 | 283,327 |
| 109 | `0xa31479cf34dac163c315abac1100bcf9dd10c1f951d84a20c2426b23ca616dd5` | 11,772,850 | 1 | 418,391 |
| 110 | `0x8596a7642b6a86923e07bd41fd3e5251dfbe5af4255d14946b847a16b9253593` | 11,772,850 | 1 | 283,327 |
| 111 | `0x5e56f8e5ddf21f9d8949828d813330ceca0c8dc0f083690366cf0ed46f06c265` | 11,772,850 | 1 | 823,583 |
| 112 | `0x3e2f54a378a53f0ea5cfee6c38bd60f8639083a6facd73dff4750ce932245465` | 11,772,850 | 1 | 283,327 |
| 165 | `0x38aea6a1a106deea37a1c31738428a74020c3569fd2a6dc98719ff5d7d4885af` | 11,774,987 | 1 | 462,191 |
| 166 | `0xf85b135332e5711d0535ba0140dfa85747ad7ebf020475adb578b2b7f1b2f7d9` | 11,774,988 | 1 | 283,327 |

</details>

## Verifier walks compared in 18

[18-gas-research.md](18-gas-research.md#three-verifier-designs-measured) compares the launch
verifier with two chunked walks of one proof. Each walk is every transaction to its verifier in the
block range below, taken from the broadcast of the walk script.

| verifier | transactions | blocks | total gasUsed | first transaction | last transaction |
|---|---:|---|---:|---|---|
| `0xB16FFE4827ABbAEAB8AdB53b3faeB14b15Fb5feA` | 49 | 11,730,135 to 11,730,238 | 512,576,167 | `0xd9222997c938830c993648c132fa06d8206521959173ba6ba26d5238324c98f2` (12,703,721) | `0x25d7e8ea99725110c8cc6b4872525258c54a8a0960ee3b28d55b68d140226760` (13,128,405) |
| `0xc6424447e96381bf023d0adcdf85e70ccb17af67` | 34 | 11,731,957 to 11,732,001 | 258,556,537 | `0xe9530926a72543466df9f6490af08090d12847b944dedafb2a9d8f3b96d46286` (12,695,431) | `0xa0b7f8e7677e3fa194f14be33bb9e6ab4ffc18a874b37c1e46b29a9384caf322` (2,819,270) |

## Reproducing a row

```sh
export RPC=https://ethereum-sepolia-rpc.publicnode.com
cast receipt <tx> gasUsed --rpc-url $RPC        # the gasUsed column
cast receipt <tx> blockNumber --rpc-url $RPC    # the block column
cast tx <tx> input --rpc-url $RPC               # the calldata
cast call 0x8e377752C8890E23A1E9F40eBbD41183Fc6949e2 "betaMode()(bool)" --rpc-url $RPC
cast call 0xf64c399696E10C84C73B66350b45bA0fCD860927 "soundnessBits()(uint256,uint256)" --rpc-url $RPC
cast call 0x59AA962433060D0206C3595afEb1793c621747eA "nq()(uint256)" --rpc-url $RPC
```

Some public endpoints prune receipts of older blocks. For the deployments before block 11,772,146,
use an endpoint that keeps them. The calldata of any settlement can be replayed against the adapter
with `eth_call` of `verifyBatch(proof, words)` at no cost.
