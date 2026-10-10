#!/usr/bin/env bash
# One GPU, one request at a time, foreground server.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Handle help before checking Python, CUDA, the native binary, or model files.
for argument in "$@"; do
  if [[ "$argument" == --help || "$argument" == -h ]]; then
    cat <<'HELP'
Usage: bash scripts/serve.sh [additional fngine-serve arguments]

PACK_PATH   fngine pack directory (default: the manifest's models/ location)
HOST / PORT bind address (default: 127.0.0.1 / 8002)

Uses the profile in runtime-manifest.json: 262,144-token context, model ID
qwen3.8-flash-next. Extra arguments follow the profile, so later values win
(for example --ctx 131072). Runs in the foreground; stop with Ctrl-C. The API has
no authentication; keep it on loopback or pass --api-key.
HELP
    exit 0
  fi
done

PYTHON="$ROOT/.venv/bin/python"
SERVER="$ROOT/runtime/fngine/build/apps/fngine-serve"
if [[ ! -x "$PYTHON" || ! -x "$SERVER" ]]; then
  printf 'The native server is not installed. Run bash setup.sh and choose 1.\n' >&2
  exit 1
fi

mapfile -t profile < <("$PYTHON" - "$ROOT/runtime-manifest.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    manifest = json.load(stream)
serving, model = manifest["serving"], manifest["model"]
print(f"models/{model['directory']}/{model['pack']}")
print(serving["host"])
print(serving["port"])
print(serving["model_id"])
print(serving["context"])
PY
)
PACK_PATH="${PACK_PATH:-$ROOT/${profile[0]}}"
HOST="${HOST:-${profile[1]}}"
PORT="${PORT:-${profile[2]}}"
if [[ ! -r "$PACK_PATH/manifest.json" ]]; then
  printf 'The pack is missing or unreadable: %s\nRun bash setup.sh and choose 2 to download, or set PACK_PATH.\n' "$PACK_PATH" >&2
  exit 1
fi

exec "$SERVER" --pack "$PACK_PATH" --host "$HOST" --port "$PORT" \
  --model-id "${profile[3]}" --ctx "${profile[4]}" "$@"
