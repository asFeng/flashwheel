#!/usr/bin/env bash
set -euo pipefail
COUNT="${1:-50}"
OFFSET="${2:-0}"
export COUNT OFFSET
exec "$(cd "$(dirname "$0")" && pwd)/build_from_ngc_tags.sh"
