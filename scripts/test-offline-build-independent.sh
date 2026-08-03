#!/usr/bin/env bash
# 验证 offline-build 不依赖任何真实或示例 Inventory，也不会连接目标节点。
set -euo pipefail

test_repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ansible-k8s-offline-independent.XXXXXX")
test_project_dir="${test_temp_dir}/project"
trap 'rm -rf -- "${test_temp_dir}"' EXIT INT TERM

mkdir -p -- "${test_project_dir}/ansible" "${test_project_dir}/offline"
cp -- "${test_repo_root}/ops.sh" "${test_project_dir}/ops.sh"
cp -- \
  "${test_repo_root}/ansible/commands.sh" \
  "${test_repo_root}/ansible/menu.sh" \
  "${test_project_dir}/ansible/"
cp -- \
  "${test_repo_root}/offline/commands.sh" \
  "${test_repo_root}/offline/menu.sh" \
  "${test_repo_root}/offline/defaults.yml" \
  "${test_project_dir}/offline/"
chmod +x "${test_project_dir}/ops.sh"

[[ ! -e ${test_project_dir}/ansible/inventories ]] || {
  printf '[失败] 隔离测试目录不应包含 ansible/inventories。\n' >&2
  exit 1
}

unset OPS_OFFLINE_DEFAULTS_FILE
test_output=$(
  cd -- "${test_project_dir}"
  ./ops.sh offline-build \
    --distro debian \
    --release 12 \
    --arch amd64 \
    --runtime crio \
    --addon metrics_server \
    --output "${test_temp_dir}/planned-bundle" \
    --plan
)

case "${test_output}" in
  *"容器运行时：crio（软件包 cri-o）"*"附加组件数量：1"*"当前为 --plan"*) ;;
  *)
    printf '[失败] 无 Inventory 构建计划输出不完整。\n%s\n' "${test_output}" >&2
    exit 1
    ;;
esac

printf '[通过] offline-build 在不存在 ansible/inventories 的环境中可独立生成计划。\n'
