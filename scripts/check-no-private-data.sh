#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if git -C "$repo_root" grep -InE \
  '(BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|kubeconfig:|client-key-data:|password[[:space:]]*:[[:space:]]*[^<{[]|token[[:space:]]*:[[:space:]]*[A-Za-z0-9._-]{16,})' \
  -- ':!scripts/check-no-private-data.sh'; then
  echo "Potential credential material found. Review the matches before publishing." >&2
  exit 1
fi

echo "No obvious credential material found in tracked files."
