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
    ANSIBLE_DOCKER_OFFLINE=${OPS_DOCKER_OFFLINE:-false} \
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
  while true; do
    read -r -p "${prompt_text} [y/N] " answer || return 1
    case "${answer}" in
      y|Y|yes|YES) return 0 ;;
      ""|n|N|no|NO) return 1 ;;
      *) ops_warn "请输入 y 或 n。" ;;
    esac
  done
}

# 文本输入统一支持返回和退出；结果通过 OPS_INTERACTIVE_VALUE 传给调用者。
ops_interactive_input() {
  local prompt_text=$1
  local default_value=${2:-}
  local allow_empty=${3:-false}
  local answer

  while true; do
    if [[ -n ${default_value} ]]; then
      read -r -p "${prompt_text} [${default_value}]（b 返回主菜单，q 退出）：" answer || return 3
      answer=${answer:-${default_value}}
    else
      read -r -p "${prompt_text}（b 返回主菜单，q 退出）：" answer || return 3
    fi

    case "${answer}" in
      b|B) return 2 ;;
      q|Q) return 3 ;;
    esac
    if [[ -n ${answer} || ${allow_empty} == true ]]; then
      OPS_INTERACTIVE_VALUE=${answer}
      return 0
    fi
    ops_warn "该项不能为空，请重新输入。"
  done
}

# 用编号展示固定选项，同时也接受选项的英文值，便于熟悉项目的用户快速输入。
ops_interactive_select() {
  local prompt_text=$1
  local default_value=$2
  shift 2

  local values=()
  local labels=()
  local default_index=""
  local answer
  local index

  while [[ $# -gt 0 ]]; do
    values+=("$1")
    labels+=("$2")
    shift 2
  done

  while true; do
    printf '\n%s\n' "${prompt_text}"
    for ((index = 0; index < ${#values[@]}; index++)); do
      printf '  %s. %s\n' "$((index + 1))" "${labels[index]}"
      if [[ ${values[index]} == "${default_value}" ]]; then
        default_index=$((index + 1))
      fi
    done

    if [[ -n ${default_index} ]]; then
      read -r -p "请选择 [${default_index}]（b 返回主菜单，q 退出）：" answer || return 3
      answer=${answer:-${default_index}}
    else
      read -r -p "请选择（b 返回主菜单，q 退出）：" answer || return 3
    fi

    case "${answer}" in
      b|B) return 2 ;;
      q|Q) return 3 ;;
    esac
    if [[ ${answer} == y || ${answer} == Y ]]; then
      answer=yes
    elif [[ ${answer} == n || ${answer} == N ]]; then
      answer=no
    fi
    if [[ ${answer} =~ ^[0-9]+$ ]] && \
       ((answer >= 1 && answer <= ${#values[@]})); then
      OPS_INTERACTIVE_VALUE=${values[answer - 1]}
      return 0
    fi
    for ((index = 0; index < ${#values[@]}; index++)); do
      if [[ ${answer} == "${values[index]}" ]]; then
        OPS_INTERACTIVE_VALUE=${values[index]}
        return 0
      fi
    done
    ops_warn "无效选择，请输入菜单编号。"
  done
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
  offline-load       从离线包载入 Docker 控制端镜像
  offline-serve      用离线包在首个控制平面启动 dufs 分发
  check              检查所有 Playbook 语法
  ping               检查 Ansible 到所有集群节点的连接
  addons             安装或更新 Inventory 中启用的附加组件
  reset              重置所选 Inventory 中的 Kubernetes 集群
  help               显示本帮助

常用示例：
  ./ops.sh deploy -i ansible/inventories/my-cluster/hosts.yml --executor local --mode online
  ./ops.sh deploy -i ansible/inventories/my-cluster/hosts.yml --executor docker --mode online
  ./ops.sh offline-build --distro ubuntu --release 24.04 --arch amd64
  ./ops.sh offline-load --bundle offline/bundles/<离线包目录>
  ./ops.sh deploy -i ansible/inventories/my-cluster/hosts.yml --executor docker \
    --mode offline --bundle offline/bundles/<离线包目录>

查看子命令参数：
  ./ops.sh deploy --help
  ./ops.sh offline-build --help
EOF
}

# 交互向导按功能放在对应目录；ops.sh 只负责提供通用组件和统一菜单。
# shellcheck source=ansible/menu.sh
source "${OPS_ANSIBLE_ROOT}/menu.sh"
# shellcheck source=offline/menu.sh
source "${OPS_REPO_ROOT}/offline/menu.sh"

ops_interactive_pause() {
  if [[ -t 0 ]]; then
    read -r -p $'\n按 Enter 返回主菜单……' || true
  fi
}

ops_interactive_run() {
  local status

  if ( "$@" ); then
    status=0
  else
    status=$?
  fi
  case "${status}" in
    0) ops_interactive_pause ;;
    2) ops_info "已返回主菜单。" ;;
    3) return 3 ;;
    *) ops_warn "操作未完成，请根据上面的错误信息修正后重试。" ;;
  esac
  return 0
}

ops_interactive_menu() {
  local selection

  while true; do
    cat <<'EOF'

ansible-deploy-k8s 操作菜单

  1. 部署或扩容 Kubernetes 集群
  2. 检查环境与节点连接
  3. 制作、校验或加载离线包
  4. 安装或更新附加组件
  5. 启动离线包 HTTP 分发服务（dufs）
  6. 重置 Kubernetes 集群（危险）
  0. 退出
EOF

    read -r -p "请选择操作：" selection || return 0
    case "${selection}" in
      1) ops_interactive_run ops_interactive_playbook deploy || return 0 ;;
      2) ops_interactive_run ops_interactive_checks_menu || return 0 ;;
      3) ops_interactive_run ops_interactive_offline_tools_menu || return 0 ;;
      4) ops_interactive_run ops_interactive_playbook addons || return 0 ;;
      5) ops_interactive_run ops_interactive_offline_serve || return 0 ;;
      6) ops_interactive_run ops_interactive_reset || return 0 ;;
      0|q|Q) return 0 ;;
      "") ops_warn "请输入菜单编号。" ;;
      *) ops_warn "无效的菜单选项：${selection}，请输入 0-6。" ;;
    esac
  done
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
  offline-load) ops_cmd_offline_load "$@" ;;
  offline-serve) ops_cmd_offline_serve "$@" ;;
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
