#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# Maturra Pyth Keeper
#
# Fetches the latest price VAA from Hermes and pushes it on-chain via
# updatePriceFeeds() on the Pyth contract (Base Sepolia).
#
# Usage:
#   bash script/pyth-keeper.sh              # dry-run  (default, no tx)
#   bash script/pyth-keeper.sh --broadcast  # real tx
#
# Test feed: ETH/USD (active on testnet — proves the mechanism).
# Production: swap ETH_USD_FEED for the CPI feed ID, zero other changes.
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail

BROADCAST=false
[[ "${1:-}" == "--broadcast" ]] && BROADCAST=true

# ── CONFIG ────────────────────────────────────────────────────────────────────
PYTH_ADDR="0xA2aa501b19aff244D90cc15a4Cf739D2725B5729"
ORACLE_ADDR="0x3d32884c63d87B4932F90fEe3D3EA2d8cDD2f1F7"
RPC_URL="https://sepolia.base.org"
HERMES_URL="https://hermes.pyth.network"

# ETH/USD — active on testnet, proves the keeper pipeline.
# Swap this for PYTH_CPI_ID on mainnet:
# ETH_USD_FEED="0x3c35e93113a975ab62428bcf92c6fa11d383438904aa38a79e506afac814688e"
ETH_USD_FEED="0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace"

# Staleness threshold for on-chain read (5 min for crypto feeds)
MAX_AGE=300

# ── LOAD SECRETS (never echoed) ───────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; source "$SCRIPT_DIR/../.env"; set +a
DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_KEY")

# ── HEADER ────────────────────────────────────────────────────────────────────
echo "============================================================"
if $BROADCAST; then
  echo "  MATURRA PYTH KEEPER — BROADCAST (real tx)"
else
  echo "  MATURRA PYTH KEEPER — DRY-RUN (no tx)"
fi
echo "============================================================"
echo "  Deployer  : $DEPLOYER"
echo "  Pyth      : $PYTH_ADDR"
echo "  Oracle    : $ORACLE_ADDR"
echo "  Feed      : ETH/USD"
echo "  RPC       : $RPC_URL"
echo ""

# ── [1/4] FETCH VAA FROM HERMES ──────────────────────────────────────────────
echo ">>> [1/4] Fetching price update from Hermes..."

RESPONSE=$(curl -sf \
  "${HERMES_URL}/v2/updates/price/latest?ids[]=${ETH_USD_FEED}&encoding=hex")

VAA_HEX="0x$(echo "$RESPONSE" | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(d['binary']['data'][0])")"

VAA_BYTES=$(( (${#VAA_HEX} - 2) / 2 ))

# Parse human-readable price from the response
read PRICE EXPO PUBLISH_TIME <<< "$(echo "$RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
p = d['parsed'][0]['price']
price_usd = int(p['price']) * (10 ** int(p['expo']))
print(f'{price_usd:.2f}', p['expo'], p['publish_time'])
")"

echo "  VAA size     : ${VAA_BYTES} bytes"
echo "  VAA prefix   : ${VAA_HEX:0:18}..."
echo "  ETH/USD      : \$${PRICE}"
echo "  expo         : ${EXPO}"
echo "  publishTime  : ${PUBLISH_TIME}"

# ── [2/4] GET UPDATE FEE ─────────────────────────────────────────────────────
echo ""
echo ">>> [2/4] Fetching update fee from Pyth contract..."

FEE=$(cast call "$PYTH_ADDR" \
  "getUpdateFee(bytes[])(uint256)" \
  "[$VAA_HEX]" \
  --rpc-url "$RPC_URL")

echo "  Fee required : ${FEE} wei"

# ── [3/4] CHECK DEPLOYER BALANCE ─────────────────────────────────────────────
echo ""
echo ">>> [3/4] Checking deployer balance..."

BALANCE=$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL")
BALANCE_ETH=$(cast to-unit "$BALANCE" ether)

echo "  Balance      : ${BALANCE_ETH} ETH (${BALANCE} wei)"

if (( BALANCE < FEE )); then
  echo "  ERROR: insufficient balance (need ${FEE} wei, have ${BALANCE} wei)"
  exit 1
fi
echo "  OK: balance sufficient"

# ── DRY-RUN EXIT ─────────────────────────────────────────────────────────────
if ! $BROADCAST; then
  echo ""
  echo "============================================================"
  echo "  DRY-RUN SUMMARY — no transaction sent"
  echo "============================================================"
  echo "  Would call : updatePriceFeeds(bytes[]) on Pyth"
  echo "  From       : ${DEPLOYER}"
  echo "  Value      : ${FEE} wei"
  echo "  VAA size   : ${VAA_BYTES} bytes (ETH/USD @ \$${PRICE})"
  echo ""
  echo "  All checks pass. Run with --broadcast to execute."
  echo "============================================================"
  exit 0
fi

# ── [4/4] PUSH PRICE UPDATE ON-CHAIN ─────────────────────────────────────────
echo ""
echo ">>> [4/4] Pushing price update on-chain..."

TX_HASH=$(cast send "$PYTH_ADDR" \
  "updatePriceFeeds(bytes[])" \
  "[$VAA_HEX]" \
  --value "$FEE" \
  --rpc-url "$RPC_URL" \
  --private-key "$DEPLOYER_KEY" \
  --async)

echo "  TX hash      : ${TX_HASH}"
echo "  Explorer     : https://sepolia.basescan.org/tx/${TX_HASH}"

# Wait for indexing
echo ""
echo "  Waiting for confirmation..."
cast receipt "$TX_HASH" --rpc-url "$RPC_URL" --confirmations 1 > /dev/null 2>&1 && \
  echo "  Status       : confirmed" || echo "  Status       : check explorer"

# ── [5/4] VERIFY ON-CHAIN ────────────────────────────────────────────────────
echo ""
echo ">>> [5/4] Reading price on-chain (getPriceNoOlderThan, age=${MAX_AGE}s)..."

# cast returns one value per line — use python3 for zsh-compatible parsing
read ON_PRICE ON_CONF ON_EXPO ON_PT ON_USD ON_AGE <<< "$(python3 - <<PYEOF
import subprocess, re, time
out = subprocess.check_output([
    "cast","call","$PYTH_ADDR",
    "getPriceNoOlderThan(bytes32,uint256)(int64,uint64,int32,uint256)",
    "$ETH_USD_FEED","$MAX_AGE",
    "--rpc-url","$RPC_URL"
], text=True).strip().splitlines()
price = int(re.split(r'\s', out[0])[0])
conf  = int(re.split(r'\s', out[1])[0])
expo  = int(re.split(r'\s', out[2])[0])
pt    = int(re.split(r'\s', out[3])[0])
usd   = price * (10 ** expo)
age   = int(time.time()) - pt
print(price, conf, expo, pt, f'{usd:.2f}', age)
PYEOF
)"

echo "  price        : ${ON_PRICE} (expo ${ON_EXPO})  =>  \$${ON_USD}"
echo "  conf (+-1sd) : ${ON_CONF}"
echo "  publishTime  : ${ON_PT}  (${ON_AGE}s ago)"
echo "  fresh?       : $([ "$ON_AGE" -le "$MAX_AGE" ] && echo "YES" || echo "STALE")"
echo ""
echo "============================================================"
echo "  KEEPER RUN COMPLETE"
echo "  ETH/USD on-chain: \$${ON_USD}"
echo "  TX: ${TX_HASH}"
echo "============================================================"
