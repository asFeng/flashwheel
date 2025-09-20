for d in wheels/torch*-cu*-cp*/; do
  MF="manifests/flash_attn-$(basename "$d" | sed -E 's/^torch([^-]+)-cu([^-]+)-(cp[0-9]+)/\1+\2-\3/;s/^/2.8.3+-/')" # if you want to derive; easier via jq:
  MF_JSON=$(ls manifests/flash_attn-*+torch*-"$(basename "$d" | cut -d/ -f1 | sed 's/^torch//;s/-cp.*$//;s/-cu/ cu/')"*.json 2>/dev/null || true)

  # Safer: extract values from manifest
  MF_JSON=$(ls manifests/flash_attn-*.json | tail -n1)
  TORCH=$(jq -r .torch "$MF_JSON")
  CUDA=$(jq -r .cuda "$MF_JSON")
  PYTAG=$(jq -r .python_abi "$MF_JSON")
  FAVER=$(jq -r .flash_attn_version "$MF_JSON")
  WHL="$d/$(jq -r .filename "$MF_JSON")"

  TAG="fa-${FAVER}-torch${TORCH}-cu${CUDA}-${PYTAG}"

  gh release create "$TAG" "$WHL" "$MF_JSON" \
    --title "FlashAttention ${FAVER} — Torch ${TORCH} / CUDA ${CUDA} / ${PYTAG}" \
    --notes "arches: $(jq -r .arches "$MF_JSON"); sha256: $(jq -r .sha256 "$MF_JSON")"
done
