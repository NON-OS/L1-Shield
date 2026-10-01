#!/usr/bin/env bash
# The 12-word deployment rehearsed on a Sepolia fork. DeployShapes.s.sol deploys the whole stack once from
# spec/shapes; then every pinned proof in spec/shapes settles against it, each from the same snapshot, and
# its settleBatch is measured from its own mined transaction: gasUsed, execution, calldata bytes,
# the EIP-7623 floor and the standard figure.
#
#   script/shield/verify_shapes.sh [port]
#
# Pinned proofs: their notes come from fixture secrets, so each settlement follows two stand-in
# deposits and the proof's note root written into the pool's known-root storage. Those rows are
# "pinned, root written". The three transfer shapes are one transfer, so they spend the same
# nullifiers: each settles from the snapshot taken after deployment. The policy settles only the
# flat fee or zero, so the pool is deployed with the transfers' fee, and the withdrawal's fee is
# queued (a queued fee settles from the moment it is queued).
# env: FORK_URL, BLOB0 and BLOB1 (two 1,186-byte sealed notes; default spec/shapes), and any DeployShapes
# setting. Run from the repository root; broadcasts only to the local fork.
set -euo pipefail
port=${1:-8751}
rpc=http://127.0.0.1:$port
fork=${FORK_URL:-https://ethereum-sepolia-rpc.publicnode.com}
me=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 # anvil's first unlocked account
guardian=0x70997970C51812dc3A010C7d01b50e8d4d3c79C8 # anvil's second
out=${OUT:-broadcast/verify_shapes}
mkdir -p "$out"

# the launch pool's fee router and association registry, and the Sepolia test NOX. DeployShapes deploys
# the hasher (PoseidonGoldilocksFast) unless HASHER names one.
export FEE_ROUTER=${FEE_ROUTER:-0xEBE49155459833d865737cA1288122a354f11df6}
export REGISTRY=${REGISTRY:-0x4375eE7D015aC8E404A03deb577E90b08de32Df3}
export NOX_TOKEN=${NOX_TOKEN:-0x3E5249A65CA513D5e11260222e0D26f46b465d36}
export GUARDIAN=$guardian
export IMAGE_HASH=${IMAGE_HASH:-0x72f4ccfc972a6dfd9e032031a725936e0337860bc2bebf32b137e165f71b2765}
export PERIODIC_ROOT=${PERIODIC_ROOT:-0x898b800f60f467f04ac9140fb425cd54181e4d1642f61fc38b5965d08ace2888}
export PARAM_A=${PARAM_A:-$(jq -r .A spec/shapes/params.json)}
export PARAM_AP=${PARAM_AP:-$(jq -r .Ap spec/shapes/params.json)}
export PARAM_B=${PARAM_B:-$(jq -r .B spec/shapes/params.json)}
export ETH_FEE=${ETH_FEE:-$(jq -r .fee spec/shapes/transfer-eth-shape1/request.json)}
wfee=$(jq -r .fee spec/shapes/withdraw-capped-shape1/request.json)

BLOB0=${BLOB0:-spec/shapes/blob0.bin}
BLOB1=${BLOB1:-spec/shapes/blob1.bin}

anvil --port "$port" --fork-url "$fork" --hardfork prague --gas-limit 60000000 --steps-tracing --silent &
pid=$!
trap 'kill $pid' EXIT
until cast chain-id --rpc-url "$rpc" >/dev/null 2>&1; do sleep 0.3; done
[ "$(cast chain-id --rpc-url "$rpc")" = 11155111 ] || { echo "not a Sepolia fork"; exit 1; }

forge script script/shield/DeployShapes.s.sol --rpc-url "$rpc" --unlocked --sender "$me" --broadcast --slow \
  > "$out/deploy.log" 2>&1 || { tail -40 "$out/deploy.log"; exit 1; }
cp broadcast/DeployShapes.s.sol/11155111/run-latest.json "$out/deploy.json"
pool=$(grep -o 'ShieldedPool *0x[0-9a-fA-F]*' "$out/deploy.log" | awk '{print $2}')
policy=$(grep -o 'AmountPolicy *0x[0-9a-fA-F]*' "$out/deploy.log" | awk '{print $2}')

echo "== deployment (DeployShapes, one run)"
jq -r '[.transactions, .receipts] | transpose[] |
  "\(.[0].transactionType)\t\(.[0].contractName // .[0].function // "-")\t\(.[0].contractAddress // .[0].to)\t\(.[1].gasUsed)"' \
  "$out/deploy.json" | while IFS=$'\t' read -r t n a g; do printf '  %-6s %-46s %s %12d\n' "$t" "$n" "$a" "$((g))"; done
grep -E '^  (ShapesStraight|verifier|hasher|association|ShieldedPool|AmountPolicy|RelayerRegistry|RootBounty|pending|provable)' "$out/deploy.log"

# the withdrawal's fee, queued by the deployer, who owns the policy until the Safe accepts
cast send --rpc-url "$rpc" --unlocked --from "$me" "$policy" "queueRange(uint64,uint8,uint8,uint256)" 0 15 19 "$wfee" > /dev/null

slot=$(forge inspect contracts/shield/ShieldedPool.sol:ShieldedPool storageLayout --json |
  jq -r '.storage[] | select(.label=="_knownRoot") | .slot')
snap=$(cast rpc --rpc-url "$rpc" evm_snapshot | tr -d '"')
: > "$out/settle.jsonl"
for p in transfer-eth-shape1 transfer-eth-shape2 transfer-eth-shape3 withdraw-capped-shape1; do
  [ -s "spec/shapes/$p/proof.bin" ] || continue
  cast rpc --rpc-url "$rpc" evm_revert "$snap" > /dev/null
  snap=$(cast rpc --rpc-url "$rpc" evm_snapshot | tr -d '"')
  case $p in *shape1) s=A ;; *shape2) s=Ap ;; *shape3) s=B ;; esac
  for oc in 0x0000000000000000000000000000000000000000000000000000000000000011 \
    0x0000000000000000000000000000000000000000000000000000000000000022; do
    cast send --rpc-url "$rpc" --unlocked --from "$me" --value 5000000000000000 "$pool" \
      "absorb(uint64,uint256,bytes32)" 0 5000000000000000 "$oc" > /dev/null
  done
  root=0x$(python3 -c "
import json
L=json.load(open('spec/shapes/$p/publics.json'))['publics']
print(''.join('%016x'%L[3-i] for i in range(4)))")
  cast rpc --rpc-url "$rpc" anvil_setStorageAt "$pool" "$(cast index bytes32 "$root" "$slot")" \
    0x0000000000000000000000000000000000000000000000000000000000000001 > /dev/null
  POOL=$pool SHAPE=$s PKG=spec/shapes/$p/proof.bin PUBLICS=spec/shapes/$p/publics.json NPER=59 BLOB0=$BLOB0 BLOB1=$BLOB1 \
    forge script script/shield/SettleShapes.s.sol --rpc-url "$rpc" --unlocked --sender "$me" --broadcast --slow \
    > "$out/$p.settle.log" 2>&1 || { tail -30 "$out/$p.settle.log"; exit 1; }
  cp broadcast/SettleShapes.s.sol/11155111/run-latest.json "$out/$p.settle.json"
  h=$(jq -r '.transactions[] | select((.function // "") | startswith("settleBatch")) | .hash' "$out/$p.settle.json")
  python3 script/tools/standard_gas.py "$rpc" "$h" |
    jq -c --arg p "$p" --arg s "$s" '{proof: $p, shape: $s, note: "pinned, root written"} + .' | tee -a "$out/settle.jsonl"
done
