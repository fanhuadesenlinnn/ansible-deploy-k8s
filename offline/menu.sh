#!/usr/bin/env bash
# 离线操作交互向导：负责离线包制作、选择、校验、加载和 HTTP 分发流程。

# 优先列出 offline/bundles/ 中已经生成的完整离线包，也允许手动指定目录。
ops_interactive_choose_bundle() {
  local metadata_file
  local bundle_path
  local relative_path
  local default_value=""
  local select_args=()

  if [[ -d ${OPS_REPO_ROOT}/offline/bundles ]]; then
    for metadata_file in "${OPS_REPO_ROOT}"/offline/bundles/*/metadata.yml; do
      [[ -f ${metadata_file} ]] || continue
      bundle_path=$(dirname -- "${metadata_file}")
      relative_path=${bundle_path#"${OPS_REPO_ROOT}/"}
      [[ -n ${default_value} ]] || default_value=${relative_path}
      select_args+=("${relative_path}" "$(basename -- "${bundle_path}")")
    done
  fi

  if [[ ${#select_args[@]} -eq 0 ]]; then
    ops_interactive_input "离线包目录" "" false
    return $?
  fi

  select_args+=(manual "手动输入其他目录")
  ops_interactive_select "选择离线包" "${default_value}" "${select_args[@]}" || return $?
  if [[ ${OPS_INTERACTIVE_VALUE} == manual ]]; then
    ops_interactive_input "离线包目录" "" false
  fi
}

# 常用构建参数保持在主流程，高级参数按需展开，避免新用户一次面对过多问题。
ops_interactive_offline_build() {
  local distro
  local release
  local target_arch
  local controller_arch
  local kubernetes_version
  local kubernetes_package_version
  local runtime
  local runtime_package
  local crictl_version
  local cni_choice
  local cni_plugin
  local cni_source
  local cni_manifest
  local cni_checksum
  local cni_name
  local addons
  local addon_specs
  local extra_images
  local output_path
  local advanced
  local host_arch
  local list_item
  local list_values=()
  local command_args=()

  host_arch=$(ops_normalize_arch "$(uname -m)" 2>/dev/null || printf amd64)
  ops_interactive_select "选择目标 Linux 发行版" ubuntu ubuntu Ubuntu debian Debian || return $?
  distro=${OPS_INTERACTIVE_VALUE}
  if [[ ${distro} == ubuntu ]]; then
    release=24.04
  else
    release=12
  fi
  ops_interactive_input "目标系统版本" "${release}" false || return $?
  release=${OPS_INTERACTIVE_VALUE}
  ops_interactive_select \
    "选择目标 Kubernetes 节点架构" "${host_arch}" \
    amd64 "amd64 / x86_64" arm64 "arm64 / aarch64" || return $?
  target_arch=${OPS_INTERACTIVE_VALUE}
  ops_interactive_input "Kubernetes 完整版本" "$(ops_inventory_scalar kubernetes_version)" false || return $?
  kubernetes_version=${OPS_INTERACTIVE_VALUE}
  ops_interactive_select \
    "选择目标节点容器运行时" containerd \
    containerd "containerd（默认，适用范围广）" \
    crio "CRI-O" || return $?
  runtime=${OPS_INTERACTIVE_VALUE}

  ops_interactive_select \
    "选择 CNI 清单" flannel \
    flannel "Flannel（项目内置下载地址与校验值）" \
    custom "Calico、Cilium 或其他自定义 CNI" || return $?
  cni_choice=${OPS_INTERACTIVE_VALUE}

  command_args=(
    --distro "${distro}"
    --release "${release}"
    --arch "${target_arch}"
    --kubernetes-version "${kubernetes_version}"
    --runtime "${runtime}"
  )
  if [[ ${cni_choice} == custom ]]; then
    ops_interactive_input "CNI 名称（例如 calico 或 cilium）" calico false || return $?
    cni_plugin=${OPS_INTERACTIVE_VALUE}
    ops_interactive_select \
      "选择 CNI 清单来源" url \
      url "HTTP/HTTPS URL" file "本地 YAML 文件" || return $?
    cni_source=${OPS_INTERACTIVE_VALUE}
    if [[ ${cni_source} == url ]]; then
      ops_interactive_input "CNI 清单 URL" "" false || return $?
      cni_manifest=${OPS_INTERACTIVE_VALUE}
      ops_interactive_input "CNI 清单 SHA-256（可省略 sha256: 前缀）" "" false || return $?
      cni_checksum=${OPS_INTERACTIVE_VALUE}
      if [[ ${cni_checksum} =~ ^[0-9a-fA-F]{64}$ ]]; then
        cni_checksum="sha256:${cni_checksum}"
      fi
      command_args+=(--cni "${cni_plugin}" --cni-manifest-url "${cni_manifest}" --cni-manifest-checksum "${cni_checksum}")
    else
      ops_interactive_input "CNI 清单本地文件" "" false || return $?
      cni_manifest=${OPS_INTERACTIVE_VALUE}
      command_args+=(--cni "${cni_plugin}" --cni-manifest-file "${cni_manifest}")
    fi
    ops_interactive_input "离线包内的 CNI 文件名" "${cni_plugin}.yaml" false || return $?
    cni_name=${OPS_INTERACTIVE_VALUE}
    command_args+=(--cni-manifest-name "${cni_name}")
  fi

  ops_interactive_input \
    "需要打包的附加组件（metrics_server,cert_manager,reloader；留空表示不打包）" "" true || return $?
  addons=${OPS_INTERACTIVE_VALUE//,/ }
  if [[ -n ${addons} ]]; then
    read -r -a list_values <<< "${addons}"
    for list_item in "${list_values[@]}"; do
      command_args+=(--addon "${list_item}")
    done
  fi

  ops_interactive_select \
    "是否配置高级选项" no \
    no "否，使用推荐默认值" yes "是，设置控制端架构、版本、额外镜像和输出目录" || return $?
  advanced=${OPS_INTERACTIVE_VALUE}
  if [[ ${advanced} == yes ]]; then
    ops_interactive_select \
      "选择运行 Docker/Ansible 的控制端架构" "${host_arch}" \
      amd64 "amd64 / x86_64" arm64 "arm64 / aarch64" || return $?
    controller_arch=${OPS_INTERACTIVE_VALUE}
    kubernetes_package_version="${kubernetes_version}-1.1"
    ops_interactive_input "Kubernetes deb 软件包版本" "${kubernetes_package_version}" false || return $?
    kubernetes_package_version=${OPS_INTERACTIVE_VALUE}
    crictl_version=$(ops_inventory_scalar crictl_version)
    ops_interactive_input "crictl 版本" "${crictl_version}" false || return $?
    crictl_version=${OPS_INTERACTIVE_VALUE}
    if [[ ${runtime} == containerd ]]; then
      runtime_package=containerd
    else
      runtime_package=cri-o
    fi
    ops_interactive_input "容器运行时软件包名称" "${runtime_package}" false || return $?
    runtime_package=${OPS_INTERACTIVE_VALUE}
    ops_interactive_input "自定义附加组件（name|URL|sha256:摘要，多个用逗号分隔；可留空）" "" true || return $?
    addon_specs=${OPS_INTERACTIVE_VALUE}
    ops_interactive_input "额外容器镜像（多个用逗号分隔；可留空）" "" true || return $?
    extra_images=${OPS_INTERACTIVE_VALUE}
    output_path="offline/bundles/k8s-${kubernetes_version}-${distro}-${release}-${target_arch}-${runtime}"
    ops_interactive_input "输出目录" "${output_path}" false || return $?
    output_path=${OPS_INTERACTIVE_VALUE}
    command_args+=(
      --controller-arch "${controller_arch}"
      --kubernetes-package-version "${kubernetes_package_version}"
      --crictl-version "${crictl_version}"
      --runtime-package "${runtime_package}"
      --output "${output_path}"
    )
    if [[ -n ${addon_specs} ]]; then
      addon_specs=${addon_specs//,/ }
      list_values=()
      read -r -a list_values <<< "${addon_specs}"
      for list_item in "${list_values[@]}"; do
        command_args+=(--addon-spec "${list_item}")
      done
    fi
    if [[ -n ${extra_images} ]]; then
      extra_images=${extra_images//,/ }
      list_values=()
      read -r -a list_values <<< "${extra_images}"
      for list_item in "${list_values[@]}"; do
        command_args+=(--extra-image "${list_item}")
      done
    fi
  fi

  ops_cmd_offline_build "${command_args[@]}"
}

ops_interactive_offline_tools_menu() {
  local action
  local bundle_path

  ops_interactive_select \
    "离线包操作" build \
    build "制作完整离线包（需要联网和 Docker）" \
    validate "校验离线包结构和 SHA-256" \
    load "加载离线 Docker 控制端镜像" || return $?
  action=${OPS_INTERACTIVE_VALUE}
  if [[ ${action} == build ]]; then
    ops_interactive_offline_build
    return $?
  fi

  ops_interactive_choose_bundle || return $?
  bundle_path=${OPS_INTERACTIVE_VALUE}
  if [[ ${action} == validate ]]; then
    ops_cmd_offline_validate --bundle "${bundle_path}"
  else
    ops_cmd_offline_load --bundle "${bundle_path}"
  fi
}

ops_interactive_offline_serve() {
  local inventory
  local executor
  local bundle_path

  ops_interactive_choose_inventory false || return $?
  inventory=${OPS_INTERACTIVE_VALUE}
  ops_interactive_choose_executor || return $?
  executor=${OPS_INTERACTIVE_VALUE}
  ops_interactive_choose_bundle || return $?
  bundle_path=${OPS_INTERACTIVE_VALUE}
  ops_cmd_offline_serve \
    --inventory "${inventory}" --executor "${executor}" --bundle "${bundle_path}"
}
