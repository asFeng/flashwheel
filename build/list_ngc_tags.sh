#!/usr/bin/env bash
set -euo pipefail

# Usage: list_ngc_tags.sh [COUNT] [OFFSET]
COUNT="${1:-50}"
OFFSET="${2:-0}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dep: $1" >&2; exit 1; }; }
need date; need awk; need sed; need sort; need head; need docker

REPO="nvcr.io/nvidia/pytorch"

# Generate recent month tags like 25.09-py3, 25.08-py3, ... down to ~36 months back
gen_candidates() {
  local months_back="${MONTHS_BACK:-36}"
  local i=0
  while [ "$i" -lt "$months_back" ]; do
    # two-digit year + zero-padded month
    local y m tag
    y="$(date -u -d "-$i month" +%y)"
    m="$(date -u -d "-$i month" +%m)"
    tag="${y}.${m}-py3"
    echo "$tag"
    i=$((i+1))
  done
}

# Fast existence check without pulling image
exists_tag() {
  local tag="$1"
  # Quietly check manifest; returns 0 if exists
  docker manifest inspect "${REPO}:${tag}" >/dev/null 2>&1
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CANDS_FILE="$TMP/cands.txt"; : >"$CANDS_FILE"

# 1) generate candidates and test existence
while IFS= read -r t; do
  # skip any igpu-looking strings (defensive; we don't generate them though)
  grep -q -- "-igpu" <<<"$t" && continue
  if exists_tag "$t"; then
    echo "$t" >> "$CANDS_FILE"
  fi
done < <(gen_candidates)

# 2) sort newest-first (reverse version sort), slice by OFFSET/COUNT
if [ -s "$CANDS_FILE" ]; then
  sort -Vr "$CANDS_FILE" \
    | awk "NR > ${OFFSET} && NR <= ${OFFSET} + ${COUNT} {print}"
else
  echo "ERROR: No tags found via candidate probing. Check network/registry access." >&2
  exit 1
fi
