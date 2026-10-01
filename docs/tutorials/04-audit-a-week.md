# Auditing the pool's spends

Every private spend marks its notes' nullifiers as used, in public, without saying whose they were.
`script/tools/nullifier_tree.py` collects every nullifier the pool recorded in a time window, in chain
order, and folds them into a depth-16 tree built exactly as the pool builds its own, using the pool's own
hasher. Two people who run it on the same window get the same root.

```sh
python3 script/tools/nullifier_tree.py \
  --pool 0xaEe51E82965Ec1DeD870F3f4c248Ad4AdDc3e1cb \
  --from-time 1790812800 --to-time 1791417600 --asset 1 > week.json
```

`--asset 1` keeps NOX spends only; `--asset 0` keeps ETH spends; leave it out for all.

Some public RPCs drop logs without saying so. Run it against two providers with `--rpc` and compare the
roots; the script refuses a log set that repeats a nullifier.
