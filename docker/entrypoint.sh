#!/usr/bin/env bash
# 将运行时 SSH 凭据复制到容器临时目录并收紧权限，然后执行用户传入的 Ansible 命令。
set -euo pipefail

runtime_root=${ANSIBLE_RUNTIME_ROOT:-/tmp/ansible-runtime}
runtime_ssh_dir="${runtime_root}/ssh"
runtime_ansible_home=${ANSIBLE_HOME:-"${runtime_root}/home"}
runtime_local_tmp=${ANSIBLE_LOCAL_TEMP:-"${runtime_root}/tmp"}

umask 077
mkdir -p "${runtime_ssh_dir}" "${runtime_ansible_home}" "${runtime_local_tmp}"

if [[ -n ${ANSIBLE_SSH_KEY_SOURCE:-} ]]; then
  if [[ ! -r ${ANSIBLE_SSH_KEY_SOURCE} ]]; then
    echo "无法读取挂载的 SSH 私钥：${ANSIBLE_SSH_KEY_SOURCE}" >&2
    exit 1
  fi

  install -m 0600 "${ANSIBLE_SSH_KEY_SOURCE}" "${runtime_ssh_dir}/private_key"
  export ANSIBLE_PRIVATE_KEY_FILE="${runtime_ssh_dir}/private_key"
fi

if [[ -n ${ANSIBLE_KNOWN_HOSTS_SOURCE:-} ]]; then
  if [[ ! -r ${ANSIBLE_KNOWN_HOSTS_SOURCE} ]]; then
    echo "无法读取挂载的 known_hosts：${ANSIBLE_KNOWN_HOSTS_SOURCE}" >&2
    exit 1
  fi

  install -m 0644 "${ANSIBLE_KNOWN_HOSTS_SOURCE}" "${runtime_ssh_dir}/known_hosts"
  known_hosts_option="-o UserKnownHostsFile=${runtime_ssh_dir}/known_hosts"
  export ANSIBLE_SSH_COMMON_ARGS="${ANSIBLE_SSH_COMMON_ARGS:+${ANSIBLE_SSH_COMMON_ARGS} }${known_hosts_option}"
fi

exec "$@"
