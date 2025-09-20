#!/usr/bin/env bash
set -euo pipefail

# Required input
IMAGE="${IMAGE:?Set IMAGE (e.g., nvcr.io/nvidia/pytorch:24.08-py3)}"

# Optional inputs
PY="${PY:-}"                 # leave empty to autodetect inside container
FA_TAG="${FA_TAG:-}"         # flash-attention git tag/commit (optional)
ARCHES="${ARCHES:-8.6;8.9;9.0}"
NOTES="${NOTES:-}"           # free-form label for logs/manifest

# Paths
ROOT="$(cd "$(dirname "$0")/.."; pwd)"
SRC="$ROOT/flash-attention"
OUT="$ROOT/wheels"
MAN="$ROOT/manifests"

# Preconditions
[ -d "$SRC" ] || { echo "ERROR: source folder not found: $SRC"; echo "Clone it with:"; echo "  git clone https://github.com/Dao-AILab/flash-attention.git \"$SRC\""; exit 1; }
mkdir -p "$OUT" "$MAN"

echo ">>> Pulling image: $IMAGE"
docker pull "$IMAGE"

# Give the container a unique name so we can clean it reliably
RUN_NAME="flashwheel-build-$$"

# Keep STDIN open (-i) so the heredoc is actually executed
docker run --name "$RUN_NAME" --rm -i --gpus all \
  -e TORCH_CUDA_ARCH_LIST="$ARCHES" \
  -e CUDA_HOME=/usr/local/cuda \
  -e PY="$PY" \
  -e FA_TAG="$FA_TAG" \
  -e ARCHES="$ARCHES" \
  -e NOTES="$NOTES" \
  -v "$SRC":/src \
  -v "$OUT":/out \
  -v "$MAN":/man \
  "$IMAGE" bash -s <<'CONTAINER'
set -eux

# --- Choose a Python interpreter available in the container ---
: "${PY:=}"
if [ -n "${PY}" ] && command -v "${PY}" >/dev/null 2>&1; then :; else
  for C in python3 python; do
    if command -v "$C" >/dev/null 2>&1; then PY="$C"; break; fi
  done
fi
echo "Using PY=${PY}"
"${PY}" -V

# --- Ensure tools ---
command -v git >/dev/null 2>&1 || (apt-get update && apt-get install -y git)
"${PY}" -m pip install --upgrade pip wheel build ninja cmake
command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi || true

# --- Work with the source tree ---
cd /src
# Trust the bind-mounted repo and submodules (fixes 'dubious ownership')
git config --global --add safe.directory '*'

# Optional: checkout a specific tag/commit, then init/update submodules
if [ -n "${FA_TAG:-}" ]; then
  git fetch --tags || true
  git checkout "${FA_TAG}"
fi
git submodule sync --recursive
git submodule update --init --recursive

# --- Log env info ---
"${PY}" - <<'PY'
import torch, platform, os
print('torch:', torch.__version__)
print('torch cuda:', torch.version.cuda)
print('cuda available:', torch.cuda.is_available())
print('arches:', os.environ.get('TORCH_CUDA_ARCH_LIST'))
print('platform:', platform.platform())
PY

# --- Build wheel against the container's Torch/CUDA ---
"${PY}" -m build --wheel --no-isolation

# --- Locate artifact (pick newest if multiple) ---
WHEEL="$(ls -1t dist/flash_attn-*.whl | head -n1)"
[ -n "$WHEEL" ] || { echo "No wheel produced"; exit 1; }

# --- Compute metadata (shell-safe; avoids passing args after heredoc) ---
BASENAME="$(basename "$WHEEL")"
FA_VER="$(echo "$BASENAME" | cut -d- -f2)"
PYTAG="$(echo "$BASENAME" | sed -n 's/.*-\(cp[0-9]\+\)-\1-.*/\1/p')"; [ -n "$PYTAG" ] || PYTAG="unknown"
PLAT="$(echo "$BASENAME" | awk -F'-' '{print $NF}' | sed 's/\.whl$//')"
SHA="$(sha256sum "$WHEEL" | awk '{print $1}')"

# Detect torch/cuda from inside container
TORCHV="$("${PY}" - <<'PY'
import torch; print(torch.__version__)
PY
)"
CUDAV="$("${PY}" - <<'PY'
import torch; print(torch.version.cuda)
PY
)"

# --- Place wheel in combo-named subfolder (no renaming of the wheel) ---
DEST_DIR="/out/torch${TORCHV}-cu${CUDAV}-${PYTAG}"
mkdir -p "$DEST_DIR"
cp "$WHEEL" "$DEST_DIR/"
echo "$BASENAME" > "$DEST_DIR/LATEST.txt"

# --- Write manifest JSON ---
MF="/man/flash_attn-${FA_VER}+torch${TORCHV}-cu${CUDAV}-${PYTAG}.json"
"${PY}" - <<PY
import json, os
j={
  "flash_attn_version": "${FA_VER}",
  "python_abi": "${PYTAG}",
  "platform": "${PLAT}",
  "torch": "${TORCHV}",
  "cuda": "${CUDAV}",
  "arches": "${ARCHES}",
  "sha256": "${SHA}",
  "filename": "${BASENAME}",
  "notes": "${NOTES}",
  "dest_dir": os.path.basename("${DEST_DIR}")
}
open("${MF}","w").write(json.dumps(j, indent=2))
print("Manifest:", "${MF}")
PY

echo "Built wheel: ${DEST_DIR}/${BASENAME}"
echo "Manifest:    ${MF}"
CONTAINER

# Paranoid cleanup: ensure container is gone, then force-remove the image
docker rm -f "$RUN_NAME" 2>/dev/null || true

echo ">>> Removing image: $IMAGE"
docker image rm -f "$IMAGE" || true
