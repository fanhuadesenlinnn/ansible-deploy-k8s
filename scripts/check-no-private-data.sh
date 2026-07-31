#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if git -C "$repo_root" grep -InE \
  '(BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|kubeconfig:|client-key-data:|password[[:space:]]*:[[:space:]]*[^<{[]|token[[:space:]]*:[[:space:]]*[A-Za-z0-9._-]{16,})' \
  -- ':!scripts/check-no-private-data.sh'; then
  echo "发现疑似凭据内容，发布前请检查以上匹配项。" >&2
  exit 1
fi

echo "已跟踪文件中未发现明显的凭据内容。"
