#!/usr/bin/env bash
# One command, and a NOX Shield lander runs on this machine for good: it listens for proofs on the
# public topic, checks each one, lands it through a private RPC, and collects the gas rung. Both
# services restart themselves and survive reboots.
#
#   sudo ./install.sh <pool> [root standby seconds]
#   sudo ./install.sh 0xaEe51E82965Ec1DeD870F3f4c248Ad4AdDc3e1cb 90
#
# For a fresh Linux x86-64 machine with systemd, not for a host that already runs a lander. The key is
# made here and never leaves; it holds gas money only.
#
# Two users. nox-lander holds the key (home 0700) and runs relayer.py. nox-ear runs the Waku bridge,
# whose 170-package npm tree never gets to read the key; it reaches the lander on 127.0.0.1 only.
#
# A third user, nox-waku, owns an nwaku node: a public entry point to The Waku Network for the proof
# topic, so wallets and ears are not tied to Waku's own fleet. It never sees the lander's files.
#
# Root standby: 0 on the first lander, then 60, 120, 180, 240 on the others, each below the 300 s slot. A standby lander commits a root only
# if the ones ahead of it did not, so they never race each other's commit.
set -euo pipefail
umask 077

POOL=${1:?usage: install.sh <pool> [root standby seconds]}
STANDBY=${2:-0}
PORT=8480
BOUNTY=0x0DBdEA16938d8c7efd54fBf5CEFE20EF31FA4cAd   # the production pool's root bounty
LHOME=/var/lib/nox-lander
EHOME=/var/lib/nox-ear
SRC=$(cd "$(dirname "$0")/.." && pwd)   # settlement/
REPO=$(cd "$SRC/.." && pwd)

# Pinned downloads, checked against hashes fixed in this file: no curl | bash.
NODE_V=v22.23.3
NODE_SHA=df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de
FOUNDRY_V=v1.5.0
FOUNDRY_SHA=5cd98f9092bcc28be087939491f786b2bf3ed55e492996a409e29519b8ab4dc8
# nwaku v0.38.1, pulled by content digest: docker refuses any image whose bytes do not hash to it.
NWAKU_IMAGE=wakuorg/nwaku@sha256:8ff9f04bdaebdfa9c6ebf4f596094a55bd7764e3356e01a191f98c437305e238
WHOME=/var/lib/nox-waku
# The proof topic /nox-shield/1/proof/proto autoshards to shard 6 of cluster 1 (The Waku Network, 8
# shards), checked with @waku/utils contentTopicToShardIndex.
WAKU_SHARD=6
# TWN's RLN membership contract lives on Linea Sepolia; the node reads it to validate messages.
LINEA_RPC=${NWAKU_LINEA_RPC:-https://rpc.sepolia.linea.build}
# Optional: an RLN keystore (and its password file) turns on lightpush, so wallets can publish through
# this node. Without one the node relays and serves filter, which is what ears need.
RLN_KEYSTORE=${NWAKU_RLN_KEYSTORE:-}
RLN_PASSWORD_FILE=${NWAKU_RLN_PASSWORD_FILE:-}

[ "$(uname -m)" = x86_64 ] || { echo "x86-64 only"; exit 1; }
if ss -ltn | grep -q ":$PORT "; then
  echo "port $PORT is taken: a lander already runs here. This script is for a fresh machine."; exit 1
fi

fetch() { # url sha256 dest
  curl -fsSL "$1" -o "$3"
  echo "$2  $3" | sha256sum -c --quiet || { echo "checksum mismatch: $1"; rm -f "$3"; exit 1; }
}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

if [ "$(node -v 2>/dev/null | cut -d. -f1)" != v22 ]; then
  fetch "https://nodejs.org/dist/$NODE_V/node-$NODE_V-linux-x64.tar.xz" $NODE_SHA "$tmp/node.tar.xz"
  rm -rf /opt/node && mkdir -p /opt/node && tar -xJf "$tmp/node.tar.xz" -C /opt/node --strip-components=1
  chmod -R a+rX /opt/node
  ln -sf /opt/node/bin/node /usr/local/bin/node; ln -sf /opt/node/bin/npm /usr/local/bin/npm
fi
if [ "$(forge --version 2>/dev/null | head -1 | grep -o '[0-9.]*-stable')" != "${FOUNDRY_V#v}-stable" ]; then
  fetch "https://github.com/foundry-rs/foundry/releases/download/$FOUNDRY_V/foundry_${FOUNDRY_V}_linux_amd64.tar.gz" \
    $FOUNDRY_SHA "$tmp/foundry.tgz"
  tar -xzf "$tmp/foundry.tgz" -C "$tmp" forge cast
  install -m 755 "$tmp/forge" "$tmp/cast" /usr/local/bin/
fi
command -v python3 >/dev/null || apt-get install -y python3

for u in nox-lander:$LHOME nox-ear:$EHOME nox-waku:$WHOME; do
  id "${u%%:*}" >/dev/null 2>&1 || useradd --system --home "${u#*:}" --shell /usr/sbin/nologin "${u%%:*}"
done
mkdir -p "$LHOME"/{keystore,kit,lib} "$EHOME"
# the lander's forge project reads forge-std from ../lib, as it does inside the repository
cp -r "$REPO/lander/." "$LHOME/kit/"
cp -r "$REPO/lib/forge-std" "$LHOME/lib/"
rm -rf "$LHOME/kit/out" "$LHOME/kit/cache" "$LHOME/kit/broadcast" "$LHOME/kit/input"
cp "$SRC"/{package.mjs,peers.mjs,bridge.mjs,package.json,package-lock.json} "$EHOME/"

# The password is generated, never typed: it lives on disk either way, and restarts are unattended.
if [ ! -f "$LHOME/keystore/nox-relayer" ]; then
  head -c 32 /dev/urandom | base64 > "$LHOME/password"
  CAST_PASSWORD=$(cat "$LHOME/password") cast wallet new "$LHOME/keystore" nox-relayer >/dev/null
fi
chown -R nox-lander: "$LHOME"; chmod 700 "$LHOME"; chmod 600 "$LHOME/password"
chown -R nox-ear: "$EHOME"; chmod 700 "$EHOME"

# Install the ear's dependencies as the ear, and compile the settlement script as the lander, now,
# so the first package does not wait on npm or solc.
runuser -u nox-ear -- env HOME=$EHOME npm ci --omit=dev --prefix "$EHOME" --no-audit --no-fund
runuser -u nox-lander -- env HOME=$LHOME sh -c "cd $LHOME/kit && /usr/local/bin/forge build"

# The Waku node. Docker from the distribution, the image by digest, the container as nox-waku with a
# read-only root, no capabilities and no new privileges; only its own directory is mounted.
command -v docker >/dev/null || apt-get install -y docker.io
docker pull "$NWAKU_IMAGE"
mkdir -p "$WHOME/data"
EXTIP=${NWAKU_EXTIP:-$(ip -4 route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')}
# The node key lives in a config file, not on the command line, so it stays out of ps and docker inspect.
[ -f "$WHOME/nwaku.toml" ] || printf 'nodekey = "%s"\n' "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" > "$WHOME/nwaku.toml"
LIGHTPUSH=false
if [ -n "$RLN_KEYSTORE" ] && [ -n "$RLN_PASSWORD_FILE" ]; then
  install -m 600 "$RLN_KEYSTORE" "$WHOME/rln_keystore.json"
  printf 'rln-relay-cred-path = "/data/rln_keystore.json"\nrln-relay-cred-password = "%s"\n' "$(cat "$RLN_PASSWORD_FILE")" >> "$WHOME/nwaku.toml"
  LIGHTPUSH=true
fi
chown -R nox-waku: "$WHOME"; chmod 700 "$WHOME"; chmod 600 "$WHOME/nwaku.toml"
WUID=$(id -u nox-waku); WGID=$(id -g nox-waku)

cat > /etc/systemd/system/nox-waku.service <<UNIT
[Unit]
Description=NOX Shield Waku entry node (nwaku, The Waku Network shard $WAKU_SHARD)
After=docker.service network-online.target
Requires=docker.service
[Service]
ExecStartPre=-/usr/bin/docker rm -f nox-waku
ExecStart=/usr/bin/docker run --rm --name nox-waku --user $WUID:$WGID --read-only --tmpfs /tmp \\
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 --memory 1g \\
  -v $WHOME:/data -w /data \\
  -p 60000:60000/tcp -p 8000:8000/tcp -p 9000:9000/udp -p 127.0.0.1:8645:8645/tcp \\
  $NWAKU_IMAGE --config-file=/data/nwaku.toml --preset=twn --shard=$WAKU_SHARD \\
  --relay=true --filter=true --lightpush=$LIGHTPUSH --store=false \\
  --rln-relay-eth-client-address=$LINEA_RPC \\
  --tcp-port=60000 --websocket-support=true --websocket-port=8000 \\
  --discv5-discovery=true --discv5-udp-port=9000 --nat=extip:$EXTIP \\
  --rest=true --rest-address=0.0.0.0 --rest-port=8645 --max-connections=150
ExecStop=/usr/bin/docker stop nox-waku
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now nox-waku

# The node's own websocket address, for this ear and for wallets: read from its REST API.
PEER_ID=""
for _ in $(seq 1 60); do
  PEER_ID=$(curl -fsS http://127.0.0.1:8645/info 2>/dev/null | grep -o '/p2p/[A-Za-z0-9]*' | head -1 | cut -d/ -f3) && [ -n "$PEER_ID" ] && break
  sleep 2
done
if [ -n "$PEER_ID" ]; then
  printf 'NOX_WAKU_PEERS=/ip4/127.0.0.1/tcp/8000/ws/p2p/%s\n' "$PEER_ID" > "$EHOME/peers.env"
  chown nox-ear: "$EHOME/peers.env"
else
  echo "warning: the Waku node did not answer on 127.0.0.1:8645; the ear uses the default bootstrap only"
fi

HARDEN="NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
CapabilityBoundingSet=
RestrictSUIDSGID=yes
LockPersonality=yes"

cat > /etc/systemd/system/nox-lander.service <<UNIT
[Unit]
Description=NOX Shield lander (checks and lands proofs)
After=network-online.target
Wants=network-online.target
[Service]
User=nox-lander
Environment=HOME=$LHOME RELAY_POOL=$POOL RELAY_HOME=$LHOME RELAY_KIT=$LHOME/kit RELAY_PORT=$PORT
Environment=RELAY_SEND_RPC=https://rpc-sepolia.flashbots.net RELAY_ROOT_BOUNTY=$BOUNTY
Environment=RELAY_ROOT_EVERY_S=300 RELAY_ROOT_STANDBY_S=$STANDBY RELAY_DELAY_MEAN_S=15 RELAY_DELAY_CAP_S=45
ExecStart=/usr/bin/python3 $LHOME/kit/relayer.py
ReadWritePaths=$LHOME
$HARDEN
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/nox-lander-ear.service <<UNIT
[Unit]
Description=NOX Shield lander ear (the public proof topic)
After=nox-lander.service nox-waku.service
Requires=nox-lander.service
[Service]
User=nox-ear
WorkingDirectory=$EHOME
Environment=HOME=$EHOME LANDER=http://127.0.0.1:$PORT
EnvironmentFile=-$EHOME/peers.env
ExecStart=/usr/local/bin/node bridge.mjs
ReadWritePaths=$EHOME
$HARDEN
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now nox-lander nox-lander-ear

ADDR=$(runuser -u nox-lander -- cast wallet address --keystore "$LHOME/keystore/nox-relayer" --password-file "$LHOME/password")
echo "Lander running, root standby ${STANDBY} s. Fund it (0.1 Sepolia ETH is plenty): $ADDR"
[ -n "$PEER_ID" ] && echo "Waku entry point to share: /ip4/$EXTIP/tcp/8000/ws/p2p/$PEER_ID (lightpush: $LIGHTPUSH)"
echo "Open ports: 60000/tcp, 8000/tcp, 9000/udp. Logs: journalctl -fu nox-lander -u nox-lander-ear -u nox-waku"
