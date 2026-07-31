#!/usr/bin/env bash
# 在提交或 CI 中快速发现常见私钥、kubeconfig、明文密码和长 Token。
# 这不是完整的 Secret 扫描器，但可以拦截最常见的误提交；敏感变量仍应使用 Vault 或外部密钥管理器。
set -euo pipefail

# 无论从哪个目录调用脚本，都先解析仓库根目录，确保 git grep 的范围一致。
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# git grep 只扫描已跟踪文件，避免虚拟环境或离线包产生误报。
# 排除脚本自身，否则下面用于检测凭据的正则表达式会匹配到自己。
if git -C "$repo_root" grep -InE \
  '(BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|kubeconfig:|client-key-data:|password[[:space:]]*:[[:space:]]*[^<{[]|token[[:space:]]*:[[:space:]]*[A-Za-z0-9._-]{16,})' \
  -- ':!scripts/check-no-private-data.sh'; then
  echo "发现疑似凭据内容，发布前请检查以上匹配项。" >&2
  exit 1
fi

# 成功提示也会显示在 GitHub Actions 中，便于确认检查确实执行过。
echo "已跟踪文件中未发现明显的凭据内容。"
