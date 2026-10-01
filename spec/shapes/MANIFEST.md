# Pinned proofs

The format 7 transcript (docs/05), format 7, 32-byte digests, radix 8, periodic overlay. Each proof was verified from its format 7 bytes, refused under another shape's parameters, and given a rank certificate.

| proof | shape | queries | grind | bytes | keccak256 | parameter id | DEEP nonce | rank | prove s |
|---|---|---|---|---|---|---|---|---|---|
| transfer-eth-shape1 | 1 | 19 | 28 | 93384 | `6272e55365a977ccb0b502c7edf06ea2735c3aec8fef44a143aae4ace0364c5e` | `add18dbb2dba8c5426d79bca1187f6c5221a5e86108cc49ce0909d958bb5a80a` | 333713 | 1006 of 1006 | 20.8 |
| transfer-eth-shape2 | 2 | 18 | 31 | 90592 | `ed0a8163b039f1ecfcdade2b35f2987f938dce2afe59c5f073b87282d2faf644` | `7ad145c3e095bb83fb9841d0ccf3556a3349d1cf551328166770725c88f5ae44` | 794319 | 980 of 980 | 67.2 |
| transfer-eth-shape3 | 3 | 17 | 33 | 86360 | `e2e55f33873c520787ad9d5023453d724a0bbb106bae9f1deddd1d9a9f95313f` | `94ef16ef21b538d3e4fa340ddfea9a1ddc9afbb80c725374eaa739902e37079b` | 122589 | 954 of 954 | 150.4 |
| withdraw-capped-shape1 | 1 | 19 | 28 | 95816 | `b30302339c5fd675ac27cf661dc57fa97f44ae6a0154b0c89d9bde7ddcab5793` | `add18dbb2dba8c5426d79bca1187f6c5221a5e86108cc49ce0909d958bb5a80a` | 1962 | 1006 of 1006 | 20.6 |

Periodic root: `898b800f60f467f04ac9140fb425cd54181e4d1642f61fc38b5965d08ace2888`

## Evaluator image

Computed on 26 September exactly as the launch `IMAGE_HASH` is pinned (LaunchImageTest): the 12-word
circuit's tape, emitted by the prover's `emit_transition_tape` (43 transitions, 62 boundaries, 59
periodic columns; periodic root and shape-1 parameter id reproduced exactly), encoded by `script/tools/gen_program_air.py` and
`program_form_blob.py`, and compiled by `ProgramFormImage.compiled` with 4 challenge inputs.

| item | bytes | keccak256 |
|---|---|---|
| IMAGE_HASH (image.bin) | 22,525 | `72f4ccfc972a6dfd9e032031a725936e0337860bc2bebf32b137e165f71b2765` |
| PROGRAM_HASH (program.bin) | 15,706 | `fbf04c7e48b34487877cf4e295c6d0ed5aa78a3b7b0e599eddd4991fdb671677` |
| TAPE_HASH (tape.bin) | 14,862 | `4930a5e55f43eb8c2465e3db1d9908c607196ef4d9709298214db63b53299478` |

Files: `image.bin` and `program.bin` in this directory.

Periodic columns: 59. DEEP terms: 148 (88 frame + 1 composition + 59 periodic), so the 0x09 stream is 296 accepted lanes, 74 squeezes unless a lane is refused. The round constants are not relocated in this tree, so they are not computed at z.

Parameter-identity preimage: 97 bytes, the full launch preimage (with commit grind 21 and 8 chunks) then four u32 LE: 2, 19, 1, shape id. Matches the prover's parameter-identity rule.
