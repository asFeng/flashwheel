#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.."; pwd)"

COUNT="${COUNT:-50}"
OFFSET="${OFFSET:-0}"
FA_TAG="${FA_TAG:-v2.8.3}"
ARCHES="${ARCHES:-8.6;8.9;9.0}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dep: $1" >&2; exit 1; }; }
need jq; need gh; need docker

# Resolve <owner>/<repo> (or set GH_REPO)
REPO_FULL="${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
[ -n "$REPO_FULL" ] || { echo "ERROR: cannot determine GitHub repo; set GH_REPO=<owner>/<repo>"; exit 1; }

mapfile -t TAGS < <("$ROOT/build/list_ngc_tags.sh" "$COUNT" "$OFFSET")
[ "${#TAGS[@]}" -gt 0 ] || { echo "No tags returned"; exit 1; }

echo "Will process ${#TAGS[@]} tags (offset ${OFFSET}, count ${COUNT}):"
printf '  %s\n' "${TAGS[@]}"

# Get existing release tags (up to 200; extend if needed)
RELEASE_TAGS="$( ( gh api "/repos/${REPO_FULL}/releases?per_page=100&page=1" --jq '.[].tag_name' ; \
                   gh api "/repos/${REPO_FULL}/releases?per_page=100&page=2" --jq '.[].tag_name' ) 2>/dev/null || true)"

probe_combo() {
  local image="nvcr.io/nvidia/pytorch:$1"
  # Pull manifest layers are cached quickly; then run a tiny probe
  docker pull "$image" >/dev/null
  docker run --rm -i --gpus all "$image" bash -lc '
    set -e
    py=$(command -v python3 || command -v python)
    "$py" - <<PY
import sys, torch
print("TORCH=", torch.__version__)
print("CUDA=", torch.version.cuda)
print("CPABI=cp%d%d" % (sys.version_info.major, sys.version_info.minor))
PY
  ' 2>/dev/null | tr -d "\r" || true
}

already_released() {
  local torch="$1" cuda="$2" cpabi="$3"
  grep -q -- "-torch${torch}-cu${cuda}-${cpabi}$" <<<"$RELEASE_TAGS"
}

for tag in "${TAGS[@]}"; do
  echo "=== TAG ${tag} ==="
  PROBE="$(probe_combo "$tag")" || PROBE=""
  if [ -z "$PROBE" ]; then
    echo "  (probe failed; attempting build anyway)"
    TORCHV="" CUDAV="" CPABI=""
  else
    TORCHV="$(awk -F= '/^TORCH=/{print $2}' <<<"$PROBE")"
    CUDAV="$(awk -F= '/^CUDA=/{print $2}' <<<"$PROBE")"
    CPABI="$(awk -F= '/^CPABI=/{print $2}' <<<"$PROBE")"
    echo "  torch=${TORCHV}  cuda=${CUDAV}  py=${CPABI}"
  fi

  if [ -n "$TORCHV" ] && [ -n "$CUDAV" ] && [ -n "$CPABI" ] && already_released "$TORCHV" "$CUDAV" "$CPABI"; then
    echo "  → SKIP: release exists with -torch${TORCHV}-cu${CUDAV}-${CPABI}"
    continue
  fi

  NOTES="ngc:${tag} / probe torch:${TORCHV} cuda:${CUDAV} ${CPABI}"
  IMAGE="nvcr.io/nvidia/pytorch:${tag}" FA_TAG="$FA_TAG" ARCHES="$ARCHES" NOTES="$NOTES" \
    "$ROOT/build/build_in_docker.sh"
done

docker system prune -f >/dev/null 2>&1 || true
