# Checking the verifier yourself

Nothing about NOX Shield asks you to take a proof on trust. These steps rebuild the verifier from source,
check it against the pinned proofs, and confirm the deployed contract is the one you built.

```sh
git clone https://github.com/NON-OS/L1-Shield && cd L1-Shield
forge build
forge test --match-path test/shield/NotBeforeVerifier.t.sol
```

The tests take the five pinned proofs in `spec/not-before/` (three transfers, one per shape, and two
withdrawals). Each is accepted, and each is refused when the not-before time moves one step either way,
when it is zero, and when the statement is cut short.

## The deployed verifier is the one you built

```sh
RPC=https://ethereum-sepolia-rpc.publicnode.com
V=0xDA9dD4A3e957AFD2179131273C93dabBA1186A44
cast call $V "imageHash()(bytes32)" --rpc-url $RPC
cast keccak 0x$(xxd -p spec/not-before/image.bin | tr -d '\n')
```

The two hashes match. The verifier also checks, at construction, the code hash of every contract it
calls, so a different evaluator or walk cannot be swapped in later.

```sh
cast call $V "shapeOfParams(bytes32)(uint256)" 0xccba76ed5748b5ee54dfd62935fd1d10998b5c0f84e35a9dc899905cfb1eadb5 --rpc-url $RPC
# 1: shape A, 19 queries
cast call $V "soundnessBits()(uint256,uint256)" --rpc-url $RPC
# 135 conjectured, 80 provable
```
