#!/usr/bin/env bash
# ops.sh 共用函数：统一处理日志、路径、执行环境检查和危险操作确认。

OPS_REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

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
    ops_require_command "$1" "请安装 requirements.txt 中的 Ansible 依赖，或改用 --executor docker。"
    ops_print_command "$@"
    (
      cd -- "${OPS_REPO_ROOT}" || exit 1
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
