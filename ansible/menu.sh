#!/usr/bin/env bash
# Ansible 交互向导：负责 Inventory、执行环境、部署、检查、附加组件和重置流程。

# 自动列出真实集群 Inventory；example 只在语法检查流程中出现，避免误部署示例地址。
ops_interactive_choose_inventory() {
  local allow_example=${1:-false}
  local inventory_file
  local relative_path
  local inventory_name
  local default_value=""
  local select_args=()

  for inventory_file in "${OPS_ANSIBLE_ROOT}"/inventories/*/hosts.yml; do
    [[ -f ${inventory_file} ]] || continue
    relative_path=${inventory_file#"${OPS_REPO_ROOT}/"}
    inventory_name=$(basename -- "$(dirname -- "${inventory_file}")")
    if [[ ${inventory_name} == example ]]; then
      [[ ${allow_example} == true ]] || continue
      [[ -n ${default_value} ]] || default_value=${relative_path}
      select_args+=("${relative_path}" "example（示例配置，仅建议用于语法检查）")
    else
      [[ -n ${default_value} ]] || default_value=${relative_path}
      select_args+=("${relative_path}" "${inventory_name}（${relative_path}）")
    fi
  done

  if [[ ${#select_args[@]} -eq 0 ]]; then
    ops_warn "没有发现可用的集群 Inventory，请先复制 example，或手动输入已有路径。"
    ops_interactive_input "Inventory 文件或目录" "" false
    return $?
  fi

  select_args+=(manual "手动输入其他路径")
  ops_interactive_select "选择集群 Inventory" "${default_value}" "${select_args[@]}" || return $?
  if [[ ${OPS_INTERACTIVE_VALUE} == manual ]]; then
    ops_interactive_input "Inventory 文件或目录" "" false
  fi
}

# 根据 Docker Daemon 和本机 Ansible 的可用状态给出默认执行环境。
ops_interactive_choose_executor() {
  local default_executor=docker
  local docker_label="Docker（本机只需安装 Docker）"
  local local_label="本机 Ansible（使用本机 Python/Ansible）"

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker_label="${docker_label}【推荐，已就绪】"
  elif command -v ansible-playbook >/dev/null 2>&1; then
    default_executor=local
    local_label="${local_label}【推荐，已检测到】"
  elif command -v docker >/dev/null 2>&1; then
    docker_label="${docker_label}【已安装，请先启动】"
  else
    docker_label="${docker_label}【推荐】"
  fi

  ops_interactive_select \
    "选择执行环境" "${default_executor}" \
    docker "${docker_label}" \
    local "${local_label}"
}

# 部署与附加组件共用同一向导：Inventory -> 执行环境 -> 在线/离线 -> 资源来源。
ops_interactive_playbook() {
  local command_name=$1
  local inventory
  local executor
  local install_mode
  local source_type
  local bundle_path
  local bundle_url
  local bundle_checksum
  local command_args=()

  ops_interactive_choose_inventory false || return $?
  inventory=${OPS_INTERACTIVE_VALUE}
  ops_interactive_choose_executor || return $?
  executor=${OPS_INTERACTIVE_VALUE}
  ops_interactive_select \
    "选择安装模式" online \
    online "在线安装（目标节点可以访问软件源和镜像仓库）" \
    offline "离线安装（使用提前制作的完整离线包）" || return $?
  install_mode=${OPS_INTERACTIVE_VALUE}

  command_args=(
    --inventory "${inventory}"
    --executor "${executor}"
    --mode "${install_mode}"
  )
  if [[ ${install_mode} == offline ]]; then
    ops_interactive_select \
      "选择离线包来源" local \
      local "控制端本地目录（由 Ansible 复制到节点）" \
      http "HTTP/HTTPS 归档（由所有目标节点下载）" || return $?
    source_type=${OPS_INTERACTIVE_VALUE}
    if [[ ${source_type} == local ]]; then
      ops_interactive_choose_bundle || return $?
      bundle_path=${OPS_INTERACTIVE_VALUE}
      command_args+=(--bundle "${bundle_path}")
    else
      ops_interactive_input "离线包 tar.gz 下载地址" "" false || return $?
      bundle_url=${OPS_INTERACTIVE_VALUE}
      ops_interactive_input "归档 SHA-256（可省略 sha256: 前缀）" "" false || return $?
      bundle_checksum=${OPS_INTERACTIVE_VALUE}
      if [[ ${bundle_checksum} =~ ^[0-9a-fA-F]{64}$ ]]; then
        bundle_checksum="sha256:${bundle_checksum}"
      fi
      command_args+=(--bundle-url "${bundle_url}" --checksum "${bundle_checksum}")
    fi
  fi

  if [[ ${command_name} == deploy ]]; then
    ops_cmd_deploy "${command_args[@]}"
  else
    ops_cmd_addons "${command_args[@]}"
  fi
}

ops_interactive_check() {
  local check_type=$1
  local inventory
  local executor
  local allow_example=false

  [[ ${check_type} == syntax ]] && allow_example=true
  ops_interactive_choose_inventory "${allow_example}" || return $?
  inventory=${OPS_INTERACTIVE_VALUE}
  ops_interactive_choose_executor || return $?
  executor=${OPS_INTERACTIVE_VALUE}
  if [[ ${check_type} == syntax ]]; then
    ops_cmd_check --inventory "${inventory}" --executor "${executor}"
  else
    ops_cmd_ping --inventory "${inventory}" --executor "${executor}"
  fi
}

ops_interactive_checks_menu() {
  ops_interactive_select \
    "检查环境与连接" syntax \
    syntax "检查所有 Playbook 语法（不连接节点）" \
    ping "检查 SSH/Ansible 节点连接" || return $?
  ops_interactive_check "${OPS_INTERACTIVE_VALUE}"
}

# 重置前从用户选择的 Inventory 读取名称，不要求用户先去配置文件中查找。
ops_inventory_cluster_name() {
  local inventory=$1
  local inventory_path
  local group_vars_file

  inventory_path=$(ops_resolve_inventory "${inventory}")
  group_vars_file="$(dirname -- "${inventory_path}")/group_vars/all.yml"
  [[ -f ${group_vars_file} ]] || ops_die "Inventory 缺少 group_vars/all.yml：${group_vars_file}"
  awk '$1 == "cluster_name:" {value = $2; gsub(/^"|"$/, "", value); gsub(/^\047|\047$/, "", value); print value; exit}' \
    "${group_vars_file}"
}

ops_interactive_reset() {
  local inventory
  local executor
  local cluster_name
  local typed_name

  ops_interactive_choose_inventory false || return $?
  inventory=${OPS_INTERACTIVE_VALUE}
  ops_interactive_choose_executor || return $?
  executor=${OPS_INTERACTIVE_VALUE}
  cluster_name=$(ops_inventory_cluster_name "${inventory}")
  [[ -n ${cluster_name} ]] || ops_die "无法从所选 Inventory 读取 cluster_name。"

  printf '\n即将重置的集群：%s\n' "${cluster_name}"
  while true; do
    ops_interactive_input "请输入上面显示的集群名称进行确认" "" false || return $?
    typed_name=${OPS_INTERACTIVE_VALUE}
    if [[ ${typed_name} == "${cluster_name}" ]]; then
      break
    fi
    ops_warn "集群名称不匹配，未执行重置。"
  done
  ops_cmd_reset \
    --inventory "${inventory}" --executor "${executor}" --cluster-name "${cluster_name}"
}
