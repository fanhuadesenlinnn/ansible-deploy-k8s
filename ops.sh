#!/usr/bin/env bash
# 项目统一操作入口：用同一套参数完成本机/Docker、在线/离线部署和常用运维操作。
set -euo pipefail

ops_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OPS_REPO_ROOT=${ops_script_dir}
OPS_ANSIBLE_ROOT="${OPS_REPO_ROOT}/ansible"
# 统一把相对路径按仓库根目录解释，确保从其他目录调用 ops.sh 时行为一致。
cd -- "${OPS_REPO_ROOT}"

# 下面是各部署方式共用的基础能力。它们留在统一入口中，功能实现则分别放在 ansible/、docker/、offline/。
ops_info() {
  printf '[信息] %s\n' "$*"
}

ops_warn() {
  printf '[警告] %s\n' "$*" >&2
}

ops_die() {
  printf '[错误] %s\n' "$*" >&2
  exit 1
}

ops_require_value() {
  local option_name=$1
  local option_value=${2:-}

  [[ -n ${option_value} ]] || ops_die "参数 ${option_name} 缺少值。"
}

ops_require_command() {
  local command_name=$1
  local install_hint=${2:-请先安装该命令。}

  command -v "${command_name}" >/dev/null 2>&1 || \
    ops_die "未找到 ${command_name}。${install_hint}"
}

ops_require_docker() {
  ops_require_command docker "请先安装并启动 Docker。"
  docker info >/dev/null 2>&1 || \
    ops_die "无法连接 Docker Daemon，请确认 Docker 已启动且当前用户有访问权限。"
}

ops_absolute_existing_path() {
  local requested_path=$1
  local resolved_directory

  [[ -e ${requested_path} ]] || ops_die "路径不存在：${requested_path}"
  resolved_directory=$(cd -- "$(dirname -- "${requested_path}")" && pwd)
  printf '%s/%s\n' "${resolved_directory}" "$(basename -- "${requested_path}")"
}

ops_absolute_output_path() {
  local requested_path=$1
  local output_parent

  [[ -n ${requested_path} ]] || ops_die "输出路径不能为空。"
  output_parent=$(dirname -- "${requested_path}")
  mkdir -p -- "${output_parent}"
  output_parent=$(cd -- "${output_parent}" && pwd)
  printf '%s/%s\n' "${output_parent}" "$(basename -- "${requested_path}")"
}

ops_resolve_inventory() {
  local requested_inventory=$1

  if [[ -d ${requested_inventory} ]]; then
    requested_inventory="${requested_inventory%/}/hosts.yml"
  fi

  [[ -f ${requested_inventory} ]] || ops_die "Inventory 文件不存在：${requested_inventory}"
  ops_absolute_existing_path "${requested_inventory}"
}

ops_executor_path() {
  local host_path=$1
  local executor=$2

  if [[ ${executor} == local ]]; then
    printf '%s\n' "${host_path}"
    return
  fi

  case "${host_path}" in
    "${OPS_REPO_ROOT}")
      printf '/workspace\n'
      ;;
    "${OPS_REPO_ROOT}"/*)
      printf '/workspace/%s\n' "${host_path#"${OPS_REPO_ROOT}"/}"
      ;;
    *)
      ops_die "Docker 执行环境只能访问仓库目录内的文件：${host_path}"
      ;;
  esac
}

ops_validate_executor() {
  local executor=$1

  case "${executor}" in
    local|docker) ;;
    *) ops_die "executor 只能是 local 或 docker，当前值：${executor}" ;;
  esac
}

ops_validate_mode() {
  local install_mode=$1

  case "${install_mode}" in
    online|offline) ;;
    *) ops_die "mode 只能是 online 或 offline，当前值：${install_mode}" ;;
  esac
}

ops_print_command() {
  local command_part

  printf '[命令]'
  for command_part in "$@"; do
    printf ' %q' "${command_part}"
  done
  printf '\n'
}

ops_run_ansible() {
  local executor=$1
  shift

  ops_validate_executor "${executor}"
  if [[ ${executor} == local ]]; then
    ops_require_command "$1" "请安装 ansible/requirements.txt 中的 Ansible 依赖，或改用 --executor docker。"
    ops_print_command "$@"
    (
      cd -- "${OPS_ANSIBLE_ROOT}" || exit 1
      "$@"
    )
  else
    ops_require_docker
    ops_print_command "${OPS_REPO_ROOT}/docker/run.sh" "$@"
    "${OPS_REPO_ROOT}/docker/run.sh" "$@"
  fi
}

ops_confirm() {
  local prompt_text=$1
  local assume_yes=${2:-false}
  local answer

  if [[ ${assume_yes} == true ]]; then
    return
  fi

  [[ -t 0 ]] || ops_die "非交互环境必须显式传入 --yes。"
  read -r -p "${prompt_text} [y/N] " answer
  case "${answer}" in
    y|Y|yes|YES) ;;
    *) ops_die "操作已取消。" ;;
  esac
}

ops_prompt() {
  local prompt_text=$1
  local default_value=${2:-}
  local answer

  if [[ -n ${default_value} ]]; then
    read -r -p "${prompt_text} [${default_value}]：" answer
    printf '%s\n' "${answer:-${default_value}}"
  else
    read -r -p "${prompt_text}：" answer
    printf '%s\n' "${answer}"
  fi
}

ops_sha256_file() {
  local file_path=$1

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file_path}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file_path}" | awk '{print $1}'
  else
    ops_die "未找到 sha256sum 或 shasum，无法生成归档校验和。"
  fi
}

# 各模块只实现自己的命令，所有用户操作仍由本文件统一分发。
# shellcheck source=ansible/commands.sh
source "${OPS_ANSIBLE_ROOT}/commands.sh"
# shellcheck source=offline/commands.sh
source "${OPS_REPO_ROOT}/offline/commands.sh"

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
  ./ops.sh deploy -i ansible/inventories/my-cluster/hosts.yml --executor local --mode online
  ./ops.sh deploy -i ansible/inventories/my-cluster/hosts.yml --executor docker --mode online
  ./ops.sh offline-build --distro ubuntu --release 24.04 --arch amd64
  ./ops.sh deploy -i ansible/inventories/my-cluster/hosts.yml --executor docker \
    --mode offline --bundle offline/bundles/<离线包目录>

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

  inventory=$(ops_prompt "Inventory 文件或目录" "ansible/inventories/my-cluster/hosts.yml")
  command_args=(
    --inventory "${inventory}"
    --executor "${executor}"
    --mode "${install_mode}"
  )

  if [[ ${install_mode} == offline ]]; then
    bundle_path=$(ops_prompt "离线包目录（例如 offline/bundles/k8s-1.36.3-ubuntu-24.04-amd64）" "")
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
      inventory=$(ops_prompt "Inventory 文件或目录" "ansible/inventories/example/hosts.yml")
      executor=$(ops_prompt "执行环境（local/docker）" local)
      ops_cmd_check --inventory "${inventory}" --executor "${executor}"
      ;;
    2)
      inventory=$(ops_prompt "Inventory 文件或目录" "ansible/inventories/my-cluster/hosts.yml")
      executor=$(ops_prompt "执行环境（local/docker）" local)
      ops_cmd_ping --inventory "${inventory}" --executor "${executor}"
      ;;
    3) ops_interactive_deploy local online ;;
    4) ops_interactive_deploy docker online ;;
    5) ops_interactive_offline_build ;;
    6) ops_interactive_deploy local offline ;;
    7) ops_interactive_deploy docker offline ;;
    8)
      inventory=$(ops_prompt "Inventory 文件或目录" "ansible/inventories/my-cluster/hosts.yml")
      executor=$(ops_prompt "执行环境（local/docker）" local)
      ops_cmd_addons --inventory "${inventory}" --executor "${executor}"
      ;;
    9)
      inventory=$(ops_prompt "Inventory 文件或目录" "ansible/inventories/my-cluster/hosts.yml")
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
