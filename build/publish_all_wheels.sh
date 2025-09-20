#!/usr/bin/env bash
set -euo pipefail

DRY="${DRY:-0}"
FALLBACK_FA_VER="${FALLBACK_FA_VER:-2.8.3}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dep: $1" >&2; exit 1; }; }
need gh; need jq; need sha256sum

ROOT="$(cd "$(dirname "$0")/.."; pwd)"
WHEELS_DIR="$ROOT/wheels"
MAN_DIR="$ROOT/manifests"
[ -d "$WHEELS_DIR" ] || { echo "No wheels/ at $WHEELS_DIR"; exit 1; }
mkdir -p "$MAN_DIR"

# Resolve owner/repo (prefer GH_REPO override)
REPO_FULL="${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
[ -n "$REPO_FULL" ] || { echo "ERROR: cannot determine GitHub repo; set GH_REPO=<owner>/<repo>"; exit 1; }

make_manifest() {
  local combo="$1" wheel_path="$2" out="$3"
  # combo = torch<torch>-cu<cuda>-cpXYZ
  local torch cuda cpabi
  torch="$(sed -E 's/^torch([^ -]+)-cu([^ -]+)-(cp[0-9]+)$/\1/' <<<"$combo")"
  cuda="$( sed -E 's/^torch([^ -]+)-cu([^ -]+)-(cp[0-9]+)$/\2/' <<<"$combo")"
  cpabi="$(sed -E 's/^torch([^ -]+)-cu([^ -]+)-(cp[0-9]+)$/\3/' <<<"$combo")"

  local fname sha plat faver
  fname="$(basename "$wheel_path")"
  sha="$(sha256sum "$wheel_path" | awk '{print $1}')"
  plat="$(awk -F'-' '{print $NF}' <<<"$fname" | sed 's/\.whl$//')"
  faver="$(cut -d- -f2 <<<"$fname")"; [ -n "$faver" ] || faver="$FALLBACK_FA_VER"

  jq -n --arg fa "$faver" --arg abi "$cpabi" --arg platform "$plat" \
        --arg torch "$torch" --arg cuda "$cuda" \
        --arg arches "" --arg sha "$sha" --arg file "$fname" \
        --arg notes "autogen" --arg dest "$combo" \
        '{
          flash_attn_version:$fa, python_abi:$abi, platform:$platform,
          torch:$torch, cuda:$cuda, arches:$arches,
          sha256:$sha, filename:$file, notes:$notes, dest_dir:$dest
        }' > "$out"
}

# iterate combo dirs: wheels/torch<torch>-cu<cuda>-cpXYZ/
find "$WHEELS_DIR" -maxdepth 1 -type d -name "torch*-cu*-cp*" | sort | while read -r combo_dir; do
  combo="$(basename "$combo_dir")"
  wheel="$(ls -1 "$combo_dir"/flash_attn-*.whl 2>/dev/null | head -n1)" || true
  if [ -z "${wheel:-}" ]; then
    echo "Skip $combo: no .whl found"; continue
  fi

  # 1) prefer a manifest whose .dest_dir == combo (exact match)
  man="$(jq -r --arg combo "$combo" \
        'select(.dest_dir? == $combo) | input_filename' \
        "$MAN_DIR"/flash_attn-*.json 2>/dev/null | head -n1 || true)"

  # 2) if none, try strict match by torch/cuda/abi parsed from combo
  if [ -z "${man:-}" ]; then
    torch="$(sed -E 's/^torch([^ -]+)-cu([^ -]+)-(cp[0-9]+)$/\1/' <<<"$combo")"
    cuda="$( sed -E 's/^torch([^ -]+)-cu([^ -]+)-(cp[0-9]+)$/\2/' <<<"$combo")"
    cpabi="$(sed -E 's/^torch([^ -]+)-cu([^ -]+)-(cp[0-9]+)$/\3/' <<<"$combo")"
    man="$(jq -r --arg t "$torch" --arg c "$cuda" --arg a "$cpabi" \
          'select(.torch? == $t and .cuda? == $c and .python_abi? == $a) | input_filename' \
          "$MAN_DIR"/flash_attn-*.json 2>/dev/null | head -n1 || true)"
  fi

  # 3) if still none, autogenerate manifest
  if [ -z "${man:-}" ]; then
    man="$MAN_DIR/flash_attn-autogen+${combo}.json"
    echo "No manifest for $combo → creating $man"
    make_manifest "$combo" "$wheel" "$man"
  fi

  # read fields from the (matched or generated) manifest
  FAVER="$(jq -r .flash_attn_version "$man")"
  TORCHV="$(jq -r .torch "$man")"
  CUDAV="$(jq -r .cuda "$man")"
  CPABI="$(jq -r .python_abi "$man")"
  SHA_IN="$(jq -r .sha256 "$man" 2>/dev/null || echo "")"

  # ensure sha present/updated
  if [ -z "$SHA_IN" ] || [ "$SHA_IN" = "null" ]; then
    SHA="$(sha256sum "$wheel" | awk '{print $1}')"
    tmp="$(mktemp)"; jq --arg sha "$SHA" '.sha256=$sha' "$man" > "$tmp" && mv "$tmp" "$man"
  else
    SHA="$SHA_IN"
  fi

  TAG="fa-${FAVER}-torch${TORCHV}-cu${CUDAV}-${CPABI}"

  # skip if release already exists for THIS exact combo
  if gh release view "$TAG" --repo "$REPO_FULL" >/dev/null 2>&1; then
    echo "Skip existing release: $TAG"
    continue
  fi

  echo "Publish: $TAG"
  echo "  repo:     $REPO_FULL"
  echo "  wheel:    $wheel"
  echo "  manifest: $man"
  echo "  sha256:   $SHA"

  if [ "$DRY" = "1" ]; then
    echo "(dry-run) gh release create \"$TAG\" \"$wheel\" \"$man\" --repo \"$REPO_FULL\" \
      --title \"FlashAttention ${FAVER} — Torch ${TORCHV} / CUDA ${CUDAV} / ${CPABI}\" \
      --notes \"arches: $(jq -r .arches "$man"); sha256: $SHA\""
  else
    gh release create "$TAG" "$wheel" "$man" --repo "$REPO_FULL" \
      --title "FlashAttention ${FAVER} — Torch ${TORCHV} / CUDA ${CUDAV} / ${CPABI}" \
      --notes "arches: $(jq -r .arches "$man"); sha256: $SHA"
  fi
done
