#!/usr/bin/env bash
# 离线资源模块：校验现有离线包，并通过一次性 Docker 构建容器生成新离线包。

ops_offline_usage() {
  cat <<'EOF'
用法：
  ./ops.sh offline-build --distro <ubuntu|debian> --release <版本> --arch <amd64|arm64> [选项]
  ./ops.sh offline-validate --bundle <目录>

offline-build 必填参数：
      --distro NAME              ubuntu 或 debian
      --release VERSION          例如 24.04、22.04、12
      --arch ARCH                amd64 或 arm64

常用选项：
      --kubernetes-version VER   默认读取示例 Inventory
      --runtime containerd       第一版仅支持 containerd
      --runtime-package NAME     默认 containerd
      --crictl-version VER       默认读取示例 Inventory
      --cni NAME                 默认 flannel
      --cni-manifest-url URL     非 Flannel CNI 必须指定
      --cni-manifest-checksum S  格式为 sha256:<64位摘要>
      --cni-manifest-name NAME   离线包内的清单文件名
      --extra-image IMAGE        追加镜像，可重复使用
      --output PATH              输出目录，默认位于 dist/offline/
      --plan                     只显示构建参数，不下载资源
  -h, --help                     显示帮助
EOF
}

ops_inventory_scalar() {
  local variable_name=$1
  local inventory_file="${OPS_REPO_ROOT}/inventories/example/group_vars/all.yml"

  awk -v target="${variable_name}:" \
    '$1 == target {gsub(/"/, "", $2); print $2; exit}' "${inventory_file}"
}

ops_offline_manifest_from_metadata() {
  local bundle_path=$1
  local metadata_file="${bundle_path}/metadata.yml"

  if [[ -f ${metadata_file} ]]; then
    awk -F': ' '$1 == "cni_manifest" {print $2; exit}' "${metadata_file}" | tr -d "'"
  fi
  return 0
}

ops_cleanup_offline_stage() {
  if [[ -n ${OPS_OFFLINE_STAGE_ROOT:-} && -d ${OPS_OFFLINE_STAGE_ROOT} ]]; then
    rm -rf -- "${OPS_OFFLINE_STAGE_ROOT}"
  fi
}

ops_verify_checksum_manifest() {
  local bundle_path=$1
  local checksum_file="${bundle_path}/SHA256SUMS"

  [[ -f ${checksum_file} ]] || return 0
  ops_info "验证 SHA256SUMS。"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd -- "${bundle_path}" && sha256sum --check SHA256SUMS)
  elif command -v shasum >/dev/null 2>&1; then
    (cd -- "${bundle_path}" && shasum -a 256 --check SHA256SUMS)
  else
    ops_die "离线包包含 SHA256SUMS，但本机没有 sha256sum 或 shasum。"
  fi
}

ops_offline_validate_bundle() {
  local requested_bundle=$1
  local bundle_path
  local cni_manifest=${2:-}
  local required_directory
  local package_pattern
  local matched=false

  bundle_path=$(ops_absolute_existing_path "${requested_bundle}")
  [[ -d ${bundle_path} ]] || ops_die "离线包必须是目录：${bundle_path}"

  for required_directory in bin packages images manifests; do
    [[ -d ${bundle_path}/${required_directory} ]] || \
      ops_die "离线包缺少目录：${required_directory}/"
  done

  for package_pattern in 'kubeadm_*.deb' 'kubelet_*.deb' 'kubectl_*.deb' 'containerd_*.deb'; do
    matched=false
    for package_file in "${bundle_path}"/packages/${package_pattern}; do
      if [[ -f ${package_file} ]]; then
        matched=true
        break
      fi
    done
    [[ ${matched} == true ]] || ops_die "离线包缺少 packages/${package_pattern}。"
  done

  [[ -x ${bundle_path}/bin/crictl ]] || ops_die "离线包缺少可执行文件 bin/crictl。"

  matched=false
  for image_archive in "${bundle_path}"/images/*.tar; do
    if [[ -f ${image_archive} ]]; then
      matched=true
      break
    fi
  done
  [[ ${matched} == true ]] || ops_die "离线包至少需要一个 images/*.tar。"

  if [[ -z ${cni_manifest} ]]; then
    cni_manifest=$(ops_offline_manifest_from_metadata "${bundle_path}")
  fi
  cni_manifest=${cni_manifest:-kube-flannel.yml}
  [[ -f ${bundle_path}/manifests/${cni_manifest} ]] || \
    ops_die "离线包缺少 CNI 清单 manifests/${cni_manifest}。"

  ops_verify_checksum_manifest "${bundle_path}"
  ops_info "离线包结构和校验和验证通过：${bundle_path}"
}

ops_cmd_offline_validate() {
  local bundle_path=""
  local cni_manifest=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bundle)
        ops_require_value "$1" "${2:-}"
        bundle_path=$2
        shift 2
        ;;
      --cni-manifest-name)
        ops_require_value "$1" "${2:-}"
        cni_manifest=$2
        shift 2
        ;;
      -h|--help)
        ops_offline_usage
        return
        ;;
      *) ops_die "未知参数：$1" ;;
    esac
  done

  [[ -n ${bundle_path} ]] || ops_die "offline-validate 必须提供 --bundle。"
  ops_offline_validate_bundle "${bundle_path}" "${cni_manifest}"
}

ops_cmd_offline_build() {
  local target_distro=""
  local target_release=""
  local target_arch=""
  local kubernetes_version
  local kubernetes_package_version=""
  local runtime=containerd
  local runtime_package=containerd
  local crictl_version
  local cni_plugin=flannel
  local cni_manifest_url=""
  local cni_manifest_checksum=""
  local cni_manifest_name=""
  local output_path=""
  local plan_only=false
  local extra_images=()

  kubernetes_version=$(ops_inventory_scalar kubernetes_version)
  crictl_version=$(ops_inventory_scalar crictl_version)

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --distro)
        ops_require_value "$1" "${2:-}"
        target_distro=$2
        shift 2
        ;;
      --release)
        ops_require_value "$1" "${2:-}"
        target_release=$2
        shift 2
        ;;
      --arch)
        ops_require_value "$1" "${2:-}"
        target_arch=$2
        shift 2
        ;;
      --kubernetes-version)
        ops_require_value "$1" "${2:-}"
        kubernetes_version=$2
        shift 2
        ;;
      --kubernetes-package-version)
        ops_require_value "$1" "${2:-}"
        kubernetes_package_version=$2
        shift 2
        ;;
      --runtime)
        ops_require_value "$1" "${2:-}"
        runtime=$2
        shift 2
        ;;
      --runtime-package)
        ops_require_value "$1" "${2:-}"
        runtime_package=$2
        shift 2
        ;;
      --crictl-version)
        ops_require_value "$1" "${2:-}"
        crictl_version=$2
        shift 2
        ;;
      --cni)
        ops_require_value "$1" "${2:-}"
        cni_plugin=$2
        shift 2
        ;;
      --cni-manifest-url)
        ops_require_value "$1" "${2:-}"
        cni_manifest_url=$2
        shift 2
        ;;
      --cni-manifest-checksum)
        ops_require_value "$1" "${2:-}"
        cni_manifest_checksum=$2
        shift 2
        ;;
      --cni-manifest-name)
        ops_require_value "$1" "${2:-}"
        cni_manifest_name=$2
        shift 2
        ;;
      --extra-image)
        ops_require_value "$1" "${2:-}"
        extra_images+=("$2")
        shift 2
        ;;
      --output)
        ops_require_value "$1" "${2:-}"
        output_path=$2
        shift 2
        ;;
      --plan)
        plan_only=true
        shift
        ;;
      -h|--help)
        ops_offline_usage
        return
        ;;
      *) ops_die "未知参数：$1" ;;
    esac
  done

  case "${target_distro}" in
    ubuntu|debian) ;;
    *) ops_die "--distro 只能是 ubuntu 或 debian。" ;;
  esac
  [[ ${target_release} =~ ^[A-Za-z0-9._-]+$ ]] || ops_die "--release 格式不正确。"
  case "${target_arch}" in
    amd64|arm64) ;;
    *) ops_die "--arch 只能是 amd64 或 arm64。" ;;
  esac
  [[ ${kubernetes_version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    ops_die "Kubernetes 版本必须是完整版本号，例如 1.36.3。"
  [[ ${crictl_version} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    ops_die "crictl 版本格式不正确，例如 v1.36.0。"
  [[ ${runtime} == containerd ]] || ops_die "离线包制作第一版仅支持 containerd。"
  [[ ${runtime_package} =~ ^[a-zA-Z0-9.+-]+$ ]] || ops_die "容器运行时软件包名称格式不正确。"
  [[ ${cni_plugin} =~ ^[a-zA-Z0-9._-]+$ ]] || ops_die "CNI 名称格式不正确。"

  kubernetes_package_version=${kubernetes_package_version:-${kubernetes_version}-1.1}

  if [[ ${cni_plugin} == flannel ]]; then
    cni_manifest_url=${cni_manifest_url:-https://github.com/flannel-io/flannel/releases/download/v0.28.8/kube-flannel.yml}
    cni_manifest_checksum=${cni_manifest_checksum:-sha256:4148e659a834b51fc9aadc429281c6e80c97e0e25475faacd4cc857dbd16f21b}
    cni_manifest_name=${cni_manifest_name:-kube-flannel.yml}
  fi

  [[ ${cni_manifest_url} =~ ^https?:// ]] || \
    ops_die "非 Flannel CNI 必须提供有效的 --cni-manifest-url。"
  [[ ${cni_manifest_checksum} =~ ^sha256:[0-9a-fA-F]{64}$ ]] || \
    ops_die "必须提供 sha256:<64位摘要> 格式的 CNI 清单校验和。"
  [[ ${cni_manifest_name} =~ ^[a-zA-Z0-9._-]+\.ya?ml$ ]] || \
    ops_die "CNI 清单文件名必须是安全的 .yml 或 .yaml 文件名。"

  output_path=${output_path:-${OPS_REPO_ROOT}/dist/offline/k8s-${kubernetes_version}-${target_distro}-${target_release}-${target_arch}}
  output_path=$(ops_absolute_output_path "${output_path}")
  [[ ${output_path} != *[[:space:]]* ]] || ops_die "输出路径不能包含空白字符。"
  [[ ! -e ${output_path} && ! -e ${output_path}.tar.gz ]] || \
    ops_die "输出已经存在，请更换 --output 路径：${output_path}"

  local base_image="${target_distro}:${target_release}"
  local extra_images_text=""
  if [[ ${#extra_images[@]} -gt 0 ]]; then
    extra_images_text=$(printf '%s\n' "${extra_images[@]}")
  fi

  printf '\n离线包构建计划\n'
  printf '目标系统：%s %s\n' "${target_distro}" "${target_release}"
  printf '目标架构：%s\n' "${target_arch}"
  printf 'Kubernetes：%s（deb %s）\n' "${kubernetes_version}" "${kubernetes_package_version}"
  printf '容器运行时：%s（软件包 %s）\n' "${runtime}" "${runtime_package}"
  printf 'crictl：%s\n' "${crictl_version}"
  printf 'CNI：%s（%s）\n' "${cni_plugin}" "${cni_manifest_name}"
  printf '输出目录：%s\n\n' "${output_path}"

  if [[ ${plan_only} == true ]]; then
    ops_info "当前为 --plan，不下载软件包或镜像。"
    return
  fi

  ops_require_docker
  OPS_OFFLINE_STAGE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ansible-k8s-offline.XXXXXX")
  trap ops_cleanup_offline_stage EXIT INT TERM
  mkdir -p -- "${OPS_OFFLINE_STAGE_ROOT}/bundle"

  ops_info "启动一次性 ${base_image} 构建容器；下载时长取决于镜像数量和网络速度。"
  docker run --rm \
    --platform "linux/${target_arch}" \
    --env "TARGET_DISTRO=${target_distro}" \
    --env "TARGET_RELEASE=${target_release}" \
    --env "TARGET_ARCH=${target_arch}" \
    --env "KUBERNETES_VERSION=${kubernetes_version}" \
    --env "KUBERNETES_PACKAGE_VERSION=${kubernetes_package_version}" \
    --env "KUBERNETES_IMAGE_REPOSITORY=registry.k8s.io" \
    --env "RUNTIME=${runtime}" \
    --env "RUNTIME_PACKAGE=${runtime_package}" \
    --env "CRICTL_VERSION=${crictl_version}" \
    --env "CNI_PLUGIN=${cni_plugin}" \
    --env "CNI_MANIFEST_URL=${cni_manifest_url}" \
    --env "CNI_MANIFEST_CHECKSUM=${cni_manifest_checksum}" \
    --env "CNI_MANIFEST_NAME=${cni_manifest_name}" \
    --env "EXTRA_IMAGES=${extra_images_text}" \
    --env "HOST_UID=$(id -u)" \
    --env "HOST_GID=$(id -g)" \
    --volume "${OPS_OFFLINE_STAGE_ROOT}/bundle:/bundle" \
    --volume "${OPS_REPO_ROOT}/ops/offline-builder-container.sh:/usr/local/bin/offline-builder:ro" \
    "${base_image}" \
    bash /usr/local/bin/offline-builder

  ops_offline_validate_bundle "${OPS_OFFLINE_STAGE_ROOT}/bundle" "${cni_manifest_name}"
  mkdir -p -- "$(dirname -- "${output_path}")"
  mv -- "${OPS_OFFLINE_STAGE_ROOT}/bundle" "${output_path}"
  tar -czf "${output_path}.tar.gz" -C "$(dirname -- "${output_path}")" "$(basename -- "${output_path}")"
  local archive_checksum
  archive_checksum=$(ops_sha256_file "${output_path}.tar.gz")
  printf 'sha256:%s\n' "${archive_checksum}" > "${output_path}.tar.gz.sha256"

  ops_info "离线包制作完成：${output_path}"
  ops_info "HTTP 归档：${output_path}.tar.gz"
  ops_info "归档校验和：sha256:${archive_checksum}"
  ops_cleanup_offline_stage
  OPS_OFFLINE_STAGE_ROOT=""
  trap - EXIT INT TERM
}
