#!/usr/bin/env bash
# 项目统一操作入口：用同一套参数完成本机/Docker、在线/离线部署和常用运维操作。
set -euo pipefail

ops_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=ops/common.sh
source "${ops_script_dir}/ops/common.sh"
# shellcheck source=ops/offline.sh
source "${ops_script_dir}/ops/offline.sh"
# shellcheck source=ops/deploy.sh
source "${ops_script_dir}/ops/deploy.sh"

ops_usage() {
  cat <<'EOF'
ansible-deploy-k8s 统一操作入口

用法：
  ./ops.sh                              打开交互菜单
  ./ops.sh <命令> [选项]

命令：
  deploy             在线或离线安装/扩容 Kubernetes 集群
  offline-build      在联网机器上制作离线资源包
  offline-validate   校验离线资源包结构和 SHA-256
  check              检查所有 Playbook 语法
  ping               检查 Ansible 到所有集群节点的连接
  addons             安装或更新 Inventory 中启用的附加组件
  reset              重置所选 Inventory 中的 Kubernetes 集群
  help               显示本帮助

常用示例：
  ./ops.sh deploy -i inventories/my-cluster/hosts.yml --executor local --mode online
  ./ops.sh deploy -i inventories/my-cluster/hosts.yml --executor docker --mode online
  ./ops.sh offline-build --distro ubuntu --release 24.04 --arch amd64
  ./ops.sh deploy -i inventories/my-cluster/hosts.yml --executor docker \
    --mode offline --bundle dist/offline/<离线包目录>

查看子命令参数：
  ./ops.sh deploy --help
  ./ops.sh offline-build --help
EOF
}

ops_interactive_deploy() {
  local executor=$1
  local install_mode=$2
  local inventory
  local bundle_path=""
  local command_args=()

  inventory=$(ops_prompt "Inventory 文件或目录" "inventories/my-cluster/hosts.yml")
  command_args=(
    --inventory "${inventory}"
    --executor "${executor}"
    --mode "${install_mode}"
  )

  if [[ ${install_mode} == offline ]]; then
    bundle_path=$(ops_prompt "离线包目录（例如 dist/offline/k8s-1.36.3-ubuntu-24.04-amd64）" "")
    command_args+=(--bundle "${bundle_path}")
  fi

  ops_cmd_deploy "${command_args[@]}"
}

ops_interactive_offline_build() {
  local distro
  local release
  local arch
  local kubernetes_version

  distro=$(ops_prompt "目标系统（ubuntu/debian）" ubuntu)
  release=$(ops_prompt "目标系统版本" 24.04)
  arch=$(ops_prompt "目标架构（amd64/arm64）" amd64)
  kubernetes_version=$(ops_prompt "Kubernetes 版本" "$(ops_inventory_scalar kubernetes_version)")

  ops_cmd_offline_build \
    --distro "${distro}" \
    --release "${release}" \
    --arch "${arch}" \
    --kubernetes-version "${kubernetes_version}"
}

ops_interactive_menu() {
  local selection
  local inventory
  local executor
  local cluster_name

  cat <<'EOF'

ansible-deploy-k8s 操作菜单

  1. 检查 Playbook 语法
  2. 检查节点 SSH/Ansible 连接
  3. 本机 Ansible 在线部署
  4. Docker 在线部署
  5. 制作离线包
  6. 本机 Ansible 离线部署
  7. Docker 离线部署
  8. 安装或更新附加组件
  9. 重置集群
  0. 退出
EOF

  read -r -p "请选择操作：" selection
  case "${selection}" in
    1)
      inventory=$(ops_prompt "Inventory 文件或目录" "inventories/example/hosts.yml")
      executor=$(ops_prompt "执行环境（local/docker）" local)
      ops_cmd_check --inventory "${inventory}" --executor "${executor}"
      ;;
    2)
      inventory=$(ops_prompt "Inventory 文件或目录" "inventories/my-cluster/hosts.yml")
      executor=$(ops_prompt "执行环境（local/docker）" local)
      ops_cmd_ping --inventory "${inventory}" --executor "${executor}"
      ;;
    3) ops_interactive_deploy local online ;;
    4) ops_interactive_deploy docker online ;;
    5) ops_interactive_offline_build ;;
    6) ops_interactive_deploy local offline ;;
    7) ops_interactive_deploy docker offline ;;
    8)
      inventory=$(ops_prompt "Inventory 文件或目录" "inventories/my-cluster/hosts.yml")
      executor=$(ops_prompt "执行环境（local/docker）" local)
      ops_cmd_addons --inventory "${inventory}" --executor "${executor}"
      ;;
    9)
      inventory=$(ops_prompt "Inventory 文件或目录" "inventories/my-cluster/hosts.yml")
      executor=$(ops_prompt "执行环境（local/docker）" local)
      cluster_name=$(ops_prompt "必须准确输入 cluster_name" "")
      ops_cmd_reset \
        --inventory "${inventory}" --executor "${executor}" --cluster-name "${cluster_name}"
      ;;
    0) exit 0 ;;
    *) ops_die "无效的菜单选项：${selection}" ;;
  esac
}

if [[ $# -eq 0 ]]; then
  ops_interactive_menu
  exit 0
fi

ops_command=$1
shift
case "${ops_command}" in
  deploy) ops_cmd_deploy "$@" ;;
  offline-build) ops_cmd_offline_build "$@" ;;
  offline-validate) ops_cmd_offline_validate "$@" ;;
  check) ops_cmd_check "$@" ;;
  ping) ops_cmd_ping "$@" ;;
  addons) ops_cmd_addons "$@" ;;
  reset) ops_cmd_reset "$@" ;;
  help|-h|--help) ops_usage ;;
  *)
    ops_usage >&2
    ops_die "未知命令：${ops_command}"
    ;;
esac
