#!/usr/bin/env bash
# 从任意目录调用容器化 Ansible 环境，并按需挂载单个 SSH 私钥、known_hosts 或 SSH Agent Socket。
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
compose_file="${script_dir}/compose.yml"
container_env_file="${script_dir}/.env"

if ! command -v docker >/dev/null 2>&1; then
  echo "未找到 docker 命令，请先安装并启动 Docker。" >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "当前 Docker 未提供 Compose 插件，请安装 Docker Compose。" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "无法连接 Docker Daemon，请确认 Docker 已启动且当前用户有访问权限。" >&2
  exit 1
fi

if [[ -f ${container_env_file} ]]; then
  # .env 由当前用户维护，只用于保存宿主机上的绝对路径，不会复制进镜像。
  set -a
  # shellcheck disable=SC1090
  source "${container_env_file}"
  set +a
fi

if [[ $# -eq 0 ]]; then
  echo "用法：${0} <ansible 命令> [参数...]" >&2
  echo "示例：${0} ansible-playbook -i inventories/my-cluster/hosts.yml playbooks/site.yml" >&2
  exit 2
fi

resolve_regular_file() {
  local requested_path=$1
  local resolved_directory

  if [[ ! -f ${requested_path} ]]; then
    echo "文件不存在：${requested_path}" >&2
    return 1
  fi

  resolved_directory=$(cd -- "$(dirname -- "${requested_path}")" && pwd)
  printf '%s/%s\n' "${resolved_directory}" "$(basename -- "${requested_path}")"
}

docker_arguments=(
  compose
  --file "${compose_file}"
  run
  --build
  --rm
)

# 非交互环境关闭 TTY；交互终端保留密码、Vault 和 become 提示能力。
if [[ ! -t 0 || ! -t 1 ]]; then
  docker_arguments+=(-T)
fi

if [[ -n ${ANSIBLE_SSH_PRIVATE_KEY:-} ]]; then
  ssh_private_key=$(resolve_regular_file "${ANSIBLE_SSH_PRIVATE_KEY}")
  docker_arguments+=(
    --volume "${ssh_private_key}:/run/ansible-ssh/private_key:ro"
    --env ANSIBLE_SSH_KEY_SOURCE=/run/ansible-ssh/private_key
  )
fi

known_hosts_path=${ANSIBLE_KNOWN_HOSTS:-}
host_user_home=${HOME:-}
if [[ -z ${known_hosts_path} && -n ${host_user_home} && -f ${host_user_home}/.ssh/known_hosts ]]; then
  known_hosts_path="${host_user_home}/.ssh/known_hosts"
fi

if [[ -n ${known_hosts_path} ]]; then
  known_hosts_file=$(resolve_regular_file "${known_hosts_path}")
  docker_arguments+=(
    --volume "${known_hosts_file}:/run/ansible-ssh/known_hosts:ro"
    --env ANSIBLE_KNOWN_HOSTS_SOURCE=/run/ansible-ssh/known_hosts
  )
fi

agent_socket=${ANSIBLE_SSH_AGENT_SOCKET:-${SSH_AUTH_SOCK:-}}
if [[ -z ${ANSIBLE_SSH_PRIVATE_KEY:-} && -n ${agent_socket} && -S ${agent_socket} ]]; then
  docker_arguments+=(
    --volume "${agent_socket}:/run/ansible-ssh/agent.sock"
    --env SSH_AUTH_SOCK=/run/ansible-ssh/agent.sock
  )
fi

cd -- "${repository_root}"
exec docker "${docker_arguments[@]}" ansible "$@"
