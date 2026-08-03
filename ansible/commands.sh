#!/usr/bin/env bash
# 集群操作模块：负责把统一参数转换为本机或 Docker 中执行的 Ansible 命令。

ops_deploy_usage() {
  cat <<'EOF'
用法：
  ./ops.sh deploy [选项] [-- Ansible 额外参数]

选项：
  -i, --inventory PATH       Inventory 文件或包含 hosts.yml 的目录
      --executor TYPE       local 或 docker，默认 local
      --mode MODE           online 或 offline，默认 online
      --bundle PATH         控制端上的离线包目录
      --bundle-url URL      由所有目标节点下载的离线包 tar.gz 地址
      --checksum SHA256     HTTP 归档校验和，格式为 sha256:<值>
      --yes                 跳过部署前确认
      --plan                只显示将执行的命令
  -h, --help                显示帮助
EOF
}

ops_enabled_addons() {
  local inventory_path=$1
  local group_vars_file

  group_vars_file="$(dirname -- "${inventory_path}")/group_vars/all.yml"

  [[ -f ${group_vars_file} ]] || return 0
  awk '
    $1 == "addons:" {inside = 1; next}
    inside && $0 !~ /^[[:space:]]/ {exit}
    inside && $2 == "true" {
      name = $1
      sub(/:$/, "", name)
      values = values (values == "" ? "" : ", ") name
    }
    END {print values}
  ' "${group_vars_file}"
}

ops_prepare_install_source() {
  local executor=$1
  local install_mode=$2
  local bundle_path=$3
  local bundle_url=$4
  local bundle_checksum=$5

  OPS_INSTALL_EXTRA_VARS=("-e" "install_mode=${install_mode}")
  OPS_INSTALL_SOURCE_DESCRIPTION="在线软件源和下载地址"

  if [[ ${install_mode} == online ]]; then
    [[ -z ${bundle_path} && -z ${bundle_url} && -z ${bundle_checksum} ]] || \
      ops_die "online 模式不能同时设置离线包参数。"
    return
  fi

  if [[ -n ${bundle_path} && -n ${bundle_url} ]]; then
    ops_die "offline 模式下 --bundle 与 --bundle-url 只能选择一个。"
  fi

  if [[ -n ${bundle_path} ]]; then
    local bundle_host_path
    local bundle_executor_path

    bundle_host_path=$(ops_absolute_existing_path "${bundle_path}")
    [[ -d ${bundle_host_path} ]] || ops_die "离线包路径必须是目录：${bundle_host_path}"
    ops_offline_validate_bundle "${bundle_host_path}"
    bundle_executor_path=$(ops_executor_path "${bundle_host_path}" "${executor}")
    [[ ${bundle_executor_path} != *[[:space:]]* ]] || \
      ops_die "离线包路径不能包含空白字符：${bundle_executor_path}"

    OPS_INSTALL_EXTRA_VARS+=(
      "-e" "offline_bundle_path=${bundle_executor_path}"
      "-e" "offline_bundle_url="
      "-e" "offline_bundle_checksum="
    )
    OPS_INSTALL_SOURCE_DESCRIPTION="控制端目录 ${bundle_host_path}"
    return
  fi

  [[ -n ${bundle_url} ]] || ops_die "offline 模式必须设置 --bundle 或 --bundle-url。"
  [[ ${bundle_url} =~ ^https?:// ]] || ops_die "离线包 URL 必须使用 http:// 或 https://。"
  [[ ${bundle_checksum} =~ ^sha256:[0-9a-fA-F]{64}$ ]] || \
    ops_die "使用 --bundle-url 时必须提供 sha256:<64位摘要>。"

  OPS_INSTALL_EXTRA_VARS+=(
    "-e" "offline_bundle_path="
    "-e" "offline_bundle_url=${bundle_url}"
    "-e" "offline_bundle_checksum=${bundle_checksum}"
  )
  OPS_INSTALL_SOURCE_DESCRIPTION="HTTP 归档 ${bundle_url}"
}

ops_execute_playbook() {
  local operation_name=$1
  local playbook=$2
  shift 2

  local inventory="ansible/inventories/example/hosts.yml"
  local executor=local
  local install_mode=online
  local bundle_path=""
  local bundle_url=""
  local bundle_checksum=""
  local assume_yes=false
  local plan_only=false
  local extra_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--inventory)
        ops_require_value "$1" "${2:-}"
        inventory=$2
        shift 2
        ;;
      --executor)
        ops_require_value "$1" "${2:-}"
        executor=$2
        shift 2
        ;;
      --mode)
        ops_require_value "$1" "${2:-}"
        install_mode=$2
        shift 2
        ;;
      --bundle)
        ops_require_value "$1" "${2:-}"
        bundle_path=$2
        shift 2
        ;;
      --bundle-url)
        ops_require_value "$1" "${2:-}"
        bundle_url=$2
        shift 2
        ;;
      --checksum)
        ops_require_value "$1" "${2:-}"
        bundle_checksum=$2
        shift 2
        ;;
      --yes)
        assume_yes=true
        shift
        ;;
      --plan)
        plan_only=true
        shift
        ;;
      -h|--help)
        ops_deploy_usage
        return
        ;;
      --)
        shift
        extra_args=("$@")
        break
        ;;
      *)
        ops_die "未知参数：$1。Ansible 原生参数请放在 -- 之后。"
        ;;
    esac
  done

  ops_validate_executor "${executor}"
  ops_validate_mode "${install_mode}"

  local inventory_host_path
  local inventory_executor_path
  inventory_host_path=$(ops_resolve_inventory "${inventory}")
  inventory_executor_path=$(ops_executor_path "${inventory_host_path}" "${executor}")
  ops_prepare_install_source \
    "${executor}" "${install_mode}" "${bundle_path}" "${bundle_url}" "${bundle_checksum}"

  local command=(
    ansible-playbook
    -i "${inventory_executor_path}"
    "${playbook}"
    "${OPS_INSTALL_EXTRA_VARS[@]}"
  )
  if [[ ${#extra_args[@]} -gt 0 ]]; then
    command+=("${extra_args[@]}")
  fi

  printf '\n操作：%s\n' "${operation_name}"
  printf '执行环境：%s\n' "${executor}"
  printf '安装模式：%s\n' "${install_mode}"
  printf 'Inventory：%s\n' "${inventory_host_path}"
  printf '资源来源：%s\n' "${OPS_INSTALL_SOURCE_DESCRIPTION}"
  if [[ ${playbook} == playbooks/addons.yml ]]; then
    local enabled_addons
    enabled_addons=$(ops_enabled_addons "${inventory_host_path}")
    printf '已启用附加组件：%s\n' "${enabled_addons:-无（请先在 group_vars/all.yml 中启用）}"
  fi
  printf '\n'

  if [[ ${executor} == docker ]]; then
    ops_print_command "${OPS_REPO_ROOT}/docker/run.sh" "${command[@]}"
  else
    ops_print_command "${command[@]}"
  fi

  if [[ ${plan_only} == true ]]; then
    ops_info "当前为 --plan，仅显示命令，不执行部署。"
    return
  fi

  if ! ops_confirm "确认开始${operation_name}？" "${assume_yes}"; then
    ops_info "操作已取消，未执行任何修改。"
    return 0
  fi
  # 该变量由统一入口 ops.sh 中的 ops_run_ansible 读取。
  # shellcheck disable=SC2034
  OPS_DOCKER_OFFLINE=false
  if [[ ${executor} == docker && ${install_mode} == offline ]]; then
    if [[ -n ${bundle_path} ]]; then
      # 目录模式可直接取得包内控制端镜像，因此由部署命令自动导入。
      ops_offline_load_controller_image "${bundle_path}" true
    else
      # URL 只对目标节点可见，控制端镜像必须提前从离线介质导入。
      ops_require_docker
      docker image inspect ansible-deploy-k8s-ansible:latest >/dev/null 2>&1 || \
        ops_die "使用 HTTP 离线包和 Docker 执行器前，请先运行 offline-load 导入控制端镜像。"
    fi
    # shellcheck disable=SC2034
    OPS_DOCKER_OFFLINE=true
  fi
  ops_run_ansible "${executor}" "${command[@]}"
  # shellcheck disable=SC2034
  OPS_DOCKER_OFFLINE=false
}

ops_cmd_deploy() {
  ops_execute_playbook "部署或扩容集群" playbooks/site.yml "$@"
}

ops_cmd_addons() {
  ops_execute_playbook "安装或更新附加组件" playbooks/addons.yml "$@"
}

ops_cmd_ping() {
  local inventory="ansible/inventories/example/hosts.yml"
  local executor=local

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--inventory)
        ops_require_value "$1" "${2:-}"
        inventory=$2
        shift 2
        ;;
      --executor)
        ops_require_value "$1" "${2:-}"
        executor=$2
        shift 2
        ;;
      -h|--help)
        printf '用法：./ops.sh ping -i <Inventory> [--executor local|docker]\n'
        return
        ;;
      *) ops_die "未知参数：$1" ;;
    esac
  done

  ops_validate_executor "${executor}"
  local inventory_host_path
  local inventory_executor_path
  inventory_host_path=$(ops_resolve_inventory "${inventory}")
  inventory_executor_path=$(ops_executor_path "${inventory_host_path}" "${executor}")
  ops_run_ansible \
    "${executor}" ansible -i "${inventory_executor_path}" k8s_cluster -m ansible.builtin.ping
}

ops_cmd_check() {
  local inventory="ansible/inventories/example/hosts.yml"
  local executor=local
  local inventory_host_path
  local inventory_executor_path
  local playbook

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--inventory)
        ops_require_value "$1" "${2:-}"
        inventory=$2
        shift 2
        ;;
      --executor)
        ops_require_value "$1" "${2:-}"
        executor=$2
        shift 2
        ;;
      -h|--help)
        cat <<'EOF'
用法：./ops.sh check -i <Inventory> [--executor local|docker]

依次执行 YAML、Ansible、敏感信息、Shell 功能测试和全部 Playbook 语法检查。
local 模式需要先安装 ansible/requirements-dev.txt；docker 模式只需要 Docker。
EOF
        return
        ;;
      *) ops_die "未知参数：$1" ;;
    esac
  done

  ops_validate_executor "${executor}"
  inventory_host_path=$(ops_resolve_inventory "${inventory}")
  inventory_executor_path=$(ops_executor_path "${inventory_host_path}" "${executor}")

  if [[ ${executor} == local ]]; then
    ops_require_command yamllint "请安装 ansible/requirements-dev.txt 中的开发依赖，或改用 --executor docker。"
    ops_require_command ansible-lint "请安装 ansible/requirements-dev.txt 中的开发依赖，或改用 --executor docker。"
  fi

  ops_info "检查 YAML 格式。"
  ops_run_ansible "${executor}" yamllint -c ../.yamllint.yml ..

  ops_info "检查 Ansible 内容。"
  ops_run_ansible "${executor}" ansible-lint

  ops_info "检查已跟踪文件中的敏感信息。"
  bash "${OPS_REPO_ROOT}/scripts/check-no-private-data.sh"

  ops_info "测试交互菜单导航。"
  bash "${OPS_REPO_ROOT}/scripts/test-ops-menu.sh"

  ops_info "测试离线包制作与 Inventory 解耦。"
  bash "${OPS_REPO_ROOT}/scripts/test-offline-build-independent.sh"

  ops_info "检查全部 Playbook 语法。"
  for playbook in site.yml addons.yml reset.yml artifact-server.yml; do
    ops_run_ansible \
      "${executor}" ansible-playbook -i "${inventory_executor_path}" \
      "playbooks/${playbook}" --syntax-check
  done
}

ops_cmd_reset() {
  local inventory="ansible/inventories/example/hosts.yml"
  local executor=local
  local cluster_name=""
  local assume_yes=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--inventory)
        ops_require_value "$1" "${2:-}"
        inventory=$2
        shift 2
        ;;
      --executor)
        ops_require_value "$1" "${2:-}"
        executor=$2
        shift 2
        ;;
      --cluster-name)
        ops_require_value "$1" "${2:-}"
        cluster_name=$2
        shift 2
        ;;
      --yes)
        assume_yes=true
        shift
        ;;
      -h|--help)
        printf '用法：./ops.sh reset -i <Inventory> --cluster-name <名称> [--executor local|docker] [--yes]\n'
        return
        ;;
      *) ops_die "未知参数：$1" ;;
    esac
  done

  [[ -n ${cluster_name} ]] || ops_die "reset 必须提供 --cluster-name。"
  ops_validate_executor "${executor}"
  local inventory_host_path
  local inventory_executor_path
  inventory_host_path=$(ops_resolve_inventory "${inventory}")
  inventory_executor_path=$(ops_executor_path "${inventory_host_path}" "${executor}")

  printf '\n危险操作：重置 Kubernetes 集群\n'
  printf '执行环境：%s\n' "${executor}"
  printf 'Inventory：%s\n' "${inventory_host_path}"
  printf '确认集群名称：%s\n\n' "${cluster_name}"
  if ! ops_confirm "确认删除所选节点上的 Kubernetes 和 CNI 状态？" "${assume_yes}"; then
    ops_info "操作已取消，未执行任何修改。"
    return 0
  fi
  ops_run_ansible \
    "${executor}" ansible-playbook -i "${inventory_executor_path}" playbooks/reset.yml \
    -e kubernetes_reset_confirm=true -e "kubernetes_reset_cluster_name=${cluster_name}"
}
