#!/usr/bin/env bash
# 离线资源模块：制作、校验并加载可在断网环境中使用的完整离线包。

ops_offline_usage() {
  cat <<'EOF'
用法：
  ./ops.sh offline-build --distro <ubuntu|debian> --release <版本> --arch <amd64|arm64> [选项]
  ./ops.sh offline-validate --bundle <目录>
  ./ops.sh offline-load --bundle <目录>
  ./ops.sh offline-serve --bundle <目录> -i <Inventory> [--executor local|docker]

offline-build 必填参数：
      --distro NAME              ubuntu 或 debian
      --release VERSION          例如 24.04、22.04、12
      --arch ARCH                目标节点架构：amd64 或 arm64

常用选项：
      --kubernetes-version VER   默认读取示例 Inventory
      --runtime TYPE             containerd 或 crio，默认 containerd
      --runtime-package NAME     默认随运行时选择 containerd 或 cri-o
      --crictl-version VER       默认读取示例 Inventory
      --controller-arch ARCH     Docker 控制端架构，默认按制作机推断
      --cni NAME                 默认 flannel
      --cni-manifest-url URL     CNI 最终静态清单 URL
      --cni-manifest-file PATH   CNI 最终静态清单本地文件
      --cni-manifest-checksum S  URL 必填；本地文件留空时自动计算
      --cni-manifest-name NAME   离线包内的清单文件名
      --addon NAME               打包示例配置中的附加组件，可重复使用
      --addon-spec SPEC          自定义 name|URL|sha256:<摘要>，可重复使用
      --extra-image IMAGE        追加清单无法静态发现的镜像，可重复使用
      --output PATH              输出目录，默认位于 offline/bundles/
      --plan                     只显示构建参数，不下载资源
  -h, --help                     显示帮助

offline-load 将包内控制端镜像载入本机 Docker，供完全断网时使用 --executor docker。
offline-serve 将包内 dufs 和 tar.gz 归档投放到第一台控制平面主机并启动只读 HTTP 服务。
EOF
}

ops_inventory_scalar() {
  local variable_name=$1
  local inventory_file="${OPS_ANSIBLE_ROOT}/inventories/example/group_vars/all.yml"

  awk -v target="${variable_name}:" \
    '$1 == target {gsub(/"/, "", $2); gsub(/\047/, "", $2); print $2; exit}' "${inventory_file}"
}

ops_inventory_mapping_scalar() {
  local mapping_name=$1
  local mapping_key=$2
  local inventory_file="${OPS_ANSIBLE_ROOT}/inventories/example/group_vars/all.yml"

  awk -v section="${mapping_name}:" -v target="${mapping_key}:" '
    $1 == section {inside = 1; next}
    inside && $0 !~ /^[[:space:]]/ {exit}
    inside && $1 == target {
      value = $2
      gsub(/"/, "", value)
      gsub(/\047/, "", value)
      print value
      exit
    }
  ' "${inventory_file}"
}

ops_offline_metadata_scalar() {
  local bundle_path=$1
  local key=$2

  awk -F': ' -v target="${key}" '
    $1 == target {
      value = $2
      gsub(/^"|"$/, "", value)
      gsub(/^\047|\047$/, "", value)
      print value
      exit
    }
  ' "${bundle_path}/metadata.yml"
}

ops_offline_metadata_list() {
  local bundle_path=$1
  local key=$2

  awk -v target="${key}:" '
    $0 == target {inside = 1; next}
    inside && $0 !~ /^  - / {exit}
    inside {
      value = $0
      sub(/^  - /, "", value)
      gsub(/^"|"$/, "", value)
      gsub(/^\047|\047$/, "", value)
      print value
    }
  ' "${bundle_path}/metadata.yml"
}

ops_normalize_arch() {
  case "$1" in
    amd64|x86_64) printf 'amd64\n' ;;
    arm64|aarch64) printf 'arm64\n' ;;
    *) return 1 ;;
  esac
}

ops_cleanup_offline_stage() {
  if [[ -n ${OPS_OFFLINE_STAGE_ROOT:-} && -d ${OPS_OFFLINE_STAGE_ROOT} ]]; then
    rm -rf -- "${OPS_OFFLINE_STAGE_ROOT}"
  fi
  if [[ -n ${OPS_OFFLINE_CONTROLLER_TEMP_TAG:-} ]] && command -v docker >/dev/null 2>&1; then
    docker image rm -- "${OPS_OFFLINE_CONTROLLER_TEMP_TAG}" >/dev/null 2>&1 || true
  fi
}

ops_verify_checksum_manifest() {
  local bundle_path=$1
  local checksum_file="${bundle_path}/SHA256SUMS"

  [[ -f ${checksum_file} ]] || ops_die "完整离线包缺少 SHA256SUMS。"
  ops_info "验证 SHA256SUMS。"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd -- "${bundle_path}" && sha256sum --check --quiet SHA256SUMS) || \
      ops_die "离线包 SHA-256 验证失败。"
  elif command -v shasum >/dev/null 2>&1; then
    # macOS shasum 没有 --quiet，只输出失败项，避免完整包每次打印数百行 OK。
    (cd -- "${bundle_path}" && shasum -a 256 --check SHA256SUMS | awk '$NF != "OK"') || \
      ops_die "离线包 SHA-256 验证失败。"
  else
    ops_die "本机没有 sha256sum 或 shasum，无法验证离线包。"
  fi
}

ops_require_bundle_package() {
  local bundle_path=$1
  local package_name=$2
  local package_file

  for package_file in "${bundle_path}"/packages/"${package_name}"_*.deb; do
    [[ -f ${package_file} ]] && return
  done
  ops_die "离线包缺少 packages/${package_name}_*.deb。"
}

ops_offline_validate_bundle() {
  local requested_bundle=$1
  local requested_cni_manifest=${2:-}
  local bundle_path
  local required_directory
  local actual_file
  local controller_archive
  local cni_manifest
  local runtime
  local runtime_package
  local format_version
  local complete_bundle
  local matched=false

  bundle_path=$(ops_absolute_existing_path "${requested_bundle}")
  [[ -d ${bundle_path} ]] || ops_die "离线包必须是目录：${bundle_path}"

  for required_directory in bin packages images manifests controller; do
    [[ -d ${bundle_path}/${required_directory} ]] || \
      ops_die "离线包缺少目录：${required_directory}/"
  done
  [[ -f ${bundle_path}/metadata.yml ]] || ops_die "完整离线包缺少 metadata.yml。"

  format_version=$(ops_offline_metadata_scalar "${bundle_path}" format_version)
  complete_bundle=$(ops_offline_metadata_scalar "${bundle_path}" complete_bundle)
  [[ ${format_version} == 2 && ${complete_bundle} == true ]] || \
    ops_die "只接受 format_version=2 且 complete_bundle=true 的完整离线包。"

  runtime=$(ops_offline_metadata_scalar "${bundle_path}" container_runtime)
  runtime_package=$(ops_offline_metadata_scalar "${bundle_path}" container_runtime_package)
  case "${runtime}" in
    containerd)
      [[ -n ${runtime_package} ]] || ops_die "metadata.yml 缺少容器运行时软件包名称。"
      ops_require_bundle_package "${bundle_path}" "${runtime_package}"
      ;;
    crio)
      ops_require_bundle_package "${bundle_path}" cri-o
      ops_require_bundle_package "${bundle_path}" podman
      ops_require_bundle_package "${bundle_path}" containernetworking-plugins
      ;;
    *) ops_die "metadata.yml 中的 container_runtime 只能是 containerd 或 crio。" ;;
  esac

  ops_require_bundle_package "${bundle_path}" kubeadm
  ops_require_bundle_package "${bundle_path}" kubelet
  ops_require_bundle_package "${bundle_path}" kubectl

  [[ -x ${bundle_path}/bin/crictl ]] || ops_die "离线包缺少可执行文件 bin/crictl。"
  [[ -x ${bundle_path}/bin/dufs ]] || ops_die "离线包缺少可执行文件 bin/dufs。"

  controller_archive=$(ops_offline_metadata_scalar "${bundle_path}" controller_image_archive)
  [[ -n ${controller_archive} && -f ${bundle_path}/${controller_archive} ]] || \
    ops_die "离线包缺少 metadata.yml 指定的 Docker 控制端镜像。"

  matched=false
  for actual_file in "${bundle_path}"/images/*.tar; do
    [[ -f ${actual_file} ]] && matched=true && break
  done
  [[ ${matched} == true ]] || ops_die "离线包至少需要一个 images/*.tar。"

  cni_manifest=${requested_cni_manifest:-$(ops_offline_metadata_scalar "${bundle_path}" cni_manifest)}
  [[ -n ${cni_manifest} && -f ${bundle_path}/manifests/${cni_manifest} ]] || \
    ops_die "离线包缺少 metadata.yml 指定的 CNI 清单。"

  while IFS= read -r addon_name; do
    [[ -f ${bundle_path}/manifests/addons/${addon_name}.yaml ]] || \
      ops_die "离线包缺少附加组件清单 manifests/addons/${addon_name}.yaml。"
  done < <(ops_offline_metadata_list "${bundle_path}" addons)

  # SHA256SUMS 不仅要验证其中列出的文件，也必须覆盖包内每一个普通文件。
  while IFS= read -r actual_file; do
    actual_file=${actual_file#"${bundle_path}/"}
    [[ ${actual_file} == SHA256SUMS ]] && continue
    awk '{name = $2; sub(/^\*/, "", name); if (name == target) found = 1} END {exit !found}' \
      target="${actual_file}" "${bundle_path}/SHA256SUMS" || \
      ops_die "SHA256SUMS 未覆盖文件：${actual_file}"
  done < <(find "${bundle_path}" -type f | sort)

  ops_verify_checksum_manifest "${bundle_path}"
  ops_info "完整离线包验证通过：${bundle_path}"
}

ops_offline_load_controller_image() {
  local requested_bundle=$1
  local already_validated=${2:-false}
  local bundle_path
  local archive_path
  local bundled_tag
  local controller_arch
  local docker_arch
  local runtime_tag=ansible-deploy-k8s-ansible:latest

  bundle_path=$(ops_absolute_existing_path "${requested_bundle}")
  if [[ ${already_validated} != true ]]; then
    ops_offline_validate_bundle "${bundle_path}"
  fi
  ops_require_docker

  archive_path=$(ops_offline_metadata_scalar "${bundle_path}" controller_image_archive)
  bundled_tag=$(ops_offline_metadata_scalar "${bundle_path}" controller_image_tag)
  controller_arch=$(ops_offline_metadata_scalar "${bundle_path}" controller_arch)
  docker_arch=$(ops_normalize_arch "$(docker info --format '{{.Architecture}}')") || \
    ops_die "无法识别 Docker Daemon 架构。"
  [[ ${controller_arch} == "${docker_arch}" ]] || \
    ops_die "控制端镜像架构为 ${controller_arch}，当前 Docker 架构为 ${docker_arch}。"
  [[ -n ${bundled_tag} ]] || ops_die "metadata.yml 缺少 controller_image_tag。"

  ops_info "从离线包载入 Docker 控制端镜像。"
  docker image load --input "${bundle_path}/${archive_path}"
  docker image tag "${bundled_tag}" "${runtime_tag}"
  ops_info "控制端镜像已经准备好：${runtime_tag}"
}

ops_cmd_offline_load() {
  local bundle_path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bundle)
        ops_require_value "$1" "${2:-}"
        bundle_path=$2
        shift 2
        ;;
      -h|--help)
        ops_offline_usage
        return
        ;;
      *) ops_die "未知参数：$1" ;;
    esac
  done

  [[ -n ${bundle_path} ]] || ops_die "offline-load 必须提供 --bundle。"
  ops_offline_load_controller_image "${bundle_path}"
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

ops_cmd_offline_serve() {
  local inventory="ansible/inventories/example/hosts.yml"
  local executor=local
  local bundle_path=""
  local archive_path=""
  local assume_yes=false
  local plan_only=false
  local inventory_host_path
  local inventory_executor_path
  local bundle_host_path
  local archive_host_path
  local binary_executor_path
  local archive_executor_path
  local command=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--inventory) ops_require_value "$1" "${2:-}"; inventory=$2; shift 2 ;;
      --executor) ops_require_value "$1" "${2:-}"; executor=$2; shift 2 ;;
      --bundle) ops_require_value "$1" "${2:-}"; bundle_path=$2; shift 2 ;;
      --archive) ops_require_value "$1" "${2:-}"; archive_path=$2; shift 2 ;;
      --yes) assume_yes=true; shift ;;
      --plan) plan_only=true; shift ;;
      -h|--help) ops_offline_usage; return ;;
      *) ops_die "未知参数：$1" ;;
    esac
  done

  [[ -n ${bundle_path} ]] || ops_die "offline-serve 必须提供 --bundle。"
  ops_validate_executor "${executor}"
  inventory_host_path=$(ops_resolve_inventory "${inventory}")
  inventory_executor_path=$(ops_executor_path "${inventory_host_path}" "${executor}")
  bundle_host_path=$(ops_absolute_existing_path "${bundle_path}")
  ops_offline_validate_bundle "${bundle_host_path}"
  archive_path=${archive_path:-${bundle_host_path}.tar.gz}
  archive_host_path=$(ops_absolute_existing_path "${archive_path}")
  [[ -f ${archive_host_path} ]] || ops_die "dufs 分发内容必须是 tar.gz 文件。"
  binary_executor_path=$(ops_executor_path "${bundle_host_path}/bin/dufs" "${executor}")
  archive_executor_path=$(ops_executor_path "${archive_host_path}" "${executor}")

  command=(
    ansible-playbook
    -i "${inventory_executor_path}"
    playbooks/artifact-server.yml
    -e install_mode=offline
    -e "dufs_offline_binary_path=${binary_executor_path}"
    -e "dufs_bundle_archive_path=${archive_executor_path}"
    -e "dufs_bundle_archive_name=$(basename -- "${archive_host_path}")"
  )
  printf '\n操作：启动离线 dufs 制品服务\n'
  printf '执行环境：%s\nInventory：%s\n归档：%s\nSHA-256：sha256:%s\n\n' \
    "${executor}" "${inventory_host_path}" "${archive_host_path}" "$(ops_sha256_file "${archive_host_path}")"
  ops_print_command "${command[@]}"
  if [[ ${plan_only} == true ]]; then
    ops_info "当前为 --plan，仅显示命令，不连接目标主机。"
    return
  fi

  ops_confirm "确认在第一台控制平面主机启动 dufs？" "${assume_yes}"
  # 该变量由统一入口 ops.sh 中的 ops_run_ansible 读取。
  # shellcheck disable=SC2034
  OPS_DOCKER_OFFLINE=false
  if [[ ${executor} == docker ]]; then
    ops_offline_load_controller_image "${bundle_host_path}" true
    # shellcheck disable=SC2034
    OPS_DOCKER_OFFLINE=true
  fi
  ops_run_ansible "${executor}" "${command[@]}"
  # shellcheck disable=SC2034
  OPS_DOCKER_OFFLINE=false
}

ops_cmd_offline_build() {
  local target_distro=""
  local target_release=""
  local target_arch=""
  local controller_arch=""
  local kubernetes_version
  local kubernetes_package_version=""
  local runtime=containerd
  local runtime_package=""
  local crictl_version
  local cni_plugin=flannel
  local cni_manifest_url=""
  local cni_manifest_file=""
  local cni_manifest_checksum=""
  local cni_manifest_name=""
  local dufs_version
  local output_path=""
  local plan_only=false
  local addon_name
  local addon_url
  local addon_checksum
  local addon_spec
  local base_image
  local dufs_arch
  local dufs_checksum
  local dufs_download_url
  local extra_images_text=""
  local addon_specs_text=""
  local archive_checksum
  local controller_tag
  local cni_container_file=""
  local addon_name_count=0
  local addon_spec_count=0
  local extra_image_count=0
  local docker_args=()
  local extra_images=()
  local addon_names=()
  local addon_specs=()

  kubernetes_version=$(ops_inventory_scalar kubernetes_version)
  crictl_version=$(ops_inventory_scalar crictl_version)
  dufs_version=$(ops_inventory_scalar dufs_version)

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --distro) ops_require_value "$1" "${2:-}"; target_distro=$2; shift 2 ;;
      --release) ops_require_value "$1" "${2:-}"; target_release=$2; shift 2 ;;
      --arch) ops_require_value "$1" "${2:-}"; target_arch=$2; shift 2 ;;
      --controller-arch) ops_require_value "$1" "${2:-}"; controller_arch=$2; shift 2 ;;
      --kubernetes-version) ops_require_value "$1" "${2:-}"; kubernetes_version=$2; shift 2 ;;
      --kubernetes-package-version) ops_require_value "$1" "${2:-}"; kubernetes_package_version=$2; shift 2 ;;
      --runtime) ops_require_value "$1" "${2:-}"; runtime=$2; shift 2 ;;
      --runtime-package) ops_require_value "$1" "${2:-}"; runtime_package=$2; shift 2 ;;
      --crictl-version) ops_require_value "$1" "${2:-}"; crictl_version=$2; shift 2 ;;
      --cni) ops_require_value "$1" "${2:-}"; cni_plugin=$2; shift 2 ;;
      --cni-manifest-url) ops_require_value "$1" "${2:-}"; cni_manifest_url=$2; shift 2 ;;
      --cni-manifest-file) ops_require_value "$1" "${2:-}"; cni_manifest_file=$2; shift 2 ;;
      --cni-manifest-checksum) ops_require_value "$1" "${2:-}"; cni_manifest_checksum=$2; shift 2 ;;
      --cni-manifest-name) ops_require_value "$1" "${2:-}"; cni_manifest_name=$2; shift 2 ;;
      --addon) ops_require_value "$1" "${2:-}"; addon_names+=("$2"); addon_name_count=$((addon_name_count + 1)); shift 2 ;;
      --addon-spec) ops_require_value "$1" "${2:-}"; addon_specs+=("$2"); addon_spec_count=$((addon_spec_count + 1)); shift 2 ;;
      --extra-image) ops_require_value "$1" "${2:-}"; extra_images+=("$2"); extra_image_count=$((extra_image_count + 1)); shift 2 ;;
      --output) ops_require_value "$1" "${2:-}"; output_path=$2; shift 2 ;;
      --plan) plan_only=true; shift ;;
      -h|--help) ops_offline_usage; return ;;
      *) ops_die "未知参数：$1" ;;
    esac
  done

  case "${target_distro}" in ubuntu|debian) ;; *) ops_die "--distro 只能是 ubuntu 或 debian。" ;; esac
  [[ ${target_release} =~ ^[A-Za-z0-9._-]+$ ]] || ops_die "--release 格式不正确。"
  case "${target_arch}" in amd64|arm64) ;; *) ops_die "--arch 只能是 amd64 或 arm64。" ;; esac
  [[ ${kubernetes_version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    ops_die "Kubernetes 版本必须是完整版本号，例如 1.36.3。"
  [[ ${crictl_version} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    ops_die "crictl 版本格式不正确，例如 v1.36.0。"
  case "${runtime}" in containerd|crio) ;; *) ops_die "--runtime 只能是 containerd 或 crio。" ;; esac
  runtime_package=${runtime_package:-$(if [[ ${runtime} == containerd ]]; then printf containerd; else printf cri-o; fi)}
  [[ ${runtime_package} =~ ^[a-zA-Z0-9.+-]+$ ]] || ops_die "容器运行时软件包名称格式不正确。"
  [[ ${cni_plugin} =~ ^[a-zA-Z0-9._-]+$ ]] || ops_die "CNI 名称格式不正确。"

  controller_arch=${controller_arch:-$(ops_normalize_arch "$(uname -m)")} || \
    ops_die "无法推断控制端架构，请显式提供 --controller-arch。"
  case "${controller_arch}" in amd64|arm64) ;; *) ops_die "--controller-arch 只能是 amd64 或 arm64。" ;; esac
  kubernetes_package_version=${kubernetes_package_version:-${kubernetes_version}-1.1}

  if [[ ${cni_plugin} == flannel && -z ${cni_manifest_url} && -z ${cni_manifest_file} ]]; then
    cni_manifest_url=https://github.com/flannel-io/flannel/releases/download/v0.28.8/kube-flannel.yml
    cni_manifest_checksum=sha256:4148e659a834b51fc9aadc429281c6e80c97e0e25475faacd4cc857dbd16f21b
    cni_manifest_name=kube-flannel.yml
  fi
  [[ -z ${cni_manifest_url} || -z ${cni_manifest_file} ]] || \
    ops_die "--cni-manifest-url 与 --cni-manifest-file 只能使用一个。"
  [[ -n ${cni_manifest_url} || -n ${cni_manifest_file} ]] || \
    ops_die "必须提供 CNI 清单 URL 或本地文件。"
  if [[ -n ${cni_manifest_file} ]]; then
    cni_manifest_file=$(ops_absolute_existing_path "${cni_manifest_file}")
    [[ -f ${cni_manifest_file} ]] || ops_die "CNI 清单必须是普通文件。"
    cni_manifest_checksum=${cni_manifest_checksum:-sha256:$(ops_sha256_file "${cni_manifest_file}")}
    cni_manifest_name=${cni_manifest_name:-$(basename -- "${cni_manifest_file}")}
  else
    [[ ${cni_manifest_url} =~ ^https?:// ]] || ops_die "CNI 清单 URL 必须使用 http:// 或 https://。"
  fi
  [[ ${cni_manifest_checksum} =~ ^sha256:[0-9a-fA-F]{64}$ ]] || \
    ops_die "必须提供 sha256:<64位摘要> 格式的 CNI 清单校验和。"
  [[ ${cni_manifest_name} =~ ^[a-zA-Z0-9._-]+\.ya?ml$ ]] || \
    ops_die "CNI 清单文件名必须是安全的 .yml 或 .yaml 文件名。"

  if [[ ${addon_name_count} -gt 0 ]]; then
    for addon_name in "${addon_names[@]}"; do
      [[ ${addon_name} =~ ^[a-zA-Z0-9._-]+$ ]] || ops_die "附加组件名称格式不正确：${addon_name}"
      addon_url=$(ops_inventory_mapping_scalar addon_manifests "${addon_name}")
      addon_checksum=$(ops_inventory_mapping_scalar addon_manifest_checksums "${addon_name}")
      [[ ${addon_url} =~ ^https?:// ]] || ops_die "示例 Inventory 未提供 ${addon_name} 的单行 URL。"
      [[ ${addon_checksum} =~ ^sha256:[0-9a-fA-F]{64}$ ]] || \
        ops_die "示例 Inventory 未提供 ${addon_name} 的有效 SHA-256。"
      addon_specs+=("${addon_name}|${addon_url}|${addon_checksum}")
      addon_spec_count=$((addon_spec_count + 1))
    done
  fi
  if [[ ${addon_spec_count} -gt 0 ]]; then
    for addon_spec in "${addon_specs[@]}"; do
      IFS='|' read -r addon_name addon_url addon_checksum <<< "${addon_spec}"
      [[ ${addon_name} =~ ^[a-zA-Z0-9._-]+$ && ${addon_url} =~ ^https?:// && \
         ${addon_checksum} =~ ^sha256:[0-9a-fA-F]{64}$ ]] || \
        ops_die "--addon-spec 必须是 name|URL|sha256:<64位摘要>。"
    done
  fi

  case "${target_arch}" in amd64) dufs_arch=x86_64 ;; arm64) dufs_arch=aarch64 ;; esac
  dufs_checksum=$(ops_inventory_mapping_scalar dufs_checksums "${dufs_arch}")
  [[ ${dufs_checksum} =~ ^sha256:[0-9a-fA-F]{64}$ ]] || ops_die "示例 Inventory 缺少 dufs 校验和。"
  dufs_download_url="https://github.com/sigoden/dufs/releases/download/${dufs_version}/dufs-${dufs_version}-${dufs_arch}-unknown-linux-musl.tar.gz"

  output_path=${output_path:-${OPS_REPO_ROOT}/offline/bundles/k8s-${kubernetes_version}-${target_distro}-${target_release}-${target_arch}-${runtime}}
  output_path=$(ops_absolute_output_path "${output_path}")
  [[ ${output_path} != *[[:space:]]* ]] || ops_die "输出路径不能包含空白字符。"
  [[ ! -e ${output_path} && ! -e ${output_path}.tar.gz ]] || \
    ops_die "输出已经存在，请更换 --output 路径：${output_path}"

  base_image="${target_distro}:${target_release}"
  controller_tag="ansible-deploy-k8s-ansible:bundle-${controller_arch}-${kubernetes_version}"
  [[ ${extra_image_count} -eq 0 ]] || extra_images_text=$(printf '%s\n' "${extra_images[@]}")
  [[ ${addon_spec_count} -eq 0 ]] || addon_specs_text=$(printf '%s\n' "${addon_specs[@]}")

  printf '\n完整离线包构建计划\n'
  printf '目标系统：%s %s\n' "${target_distro}" "${target_release}"
  printf '目标架构：%s\n' "${target_arch}"
  printf 'Docker 控制端架构：%s\n' "${controller_arch}"
  printf 'Kubernetes：%s（deb %s）\n' "${kubernetes_version}" "${kubernetes_package_version}"
  printf '容器运行时：%s（软件包 %s）\n' "${runtime}" "${runtime_package}"
  printf 'crictl：%s；dufs：%s\n' "${crictl_version}" "${dufs_version}"
  printf 'CNI：%s（%s）\n' "${cni_plugin}" "${cni_manifest_name}"
  printf '附加组件数量：%s\n' "${addon_spec_count}"
  printf '输出目录：%s\n\n' "${output_path}"

  if [[ ${plan_only} == true ]]; then
    ops_info "当前为 --plan，不下载软件包、二进制或镜像。"
    return
  fi

  ops_require_docker
  OPS_OFFLINE_STAGE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ansible-k8s-offline.XXXXXX")
  OPS_OFFLINE_CONTROLLER_TEMP_TAG=${controller_tag}
  trap ops_cleanup_offline_stage EXIT INT TERM
  mkdir -p -- "${OPS_OFFLINE_STAGE_ROOT}/bundle/controller"

  ops_info "构建并保存可断网运行的 Ansible 控制端镜像。"
  docker build \
    --platform "linux/${controller_arch}" \
    --tag "${controller_tag}" \
    --file "${OPS_REPO_ROOT}/docker/Dockerfile" \
    "${OPS_REPO_ROOT}"
  docker image save \
    --output "${OPS_OFFLINE_STAGE_ROOT}/bundle/controller/ansible-controller-image.tar" \
    "${controller_tag}"

  docker_args=(
    run --rm
    --platform "linux/${target_arch}"
    --env "TARGET_DISTRO=${target_distro}"
    --env "TARGET_RELEASE=${target_release}"
    --env "TARGET_ARCH=${target_arch}"
    --env "KUBERNETES_VERSION=${kubernetes_version}"
    --env "KUBERNETES_PACKAGE_VERSION=${kubernetes_package_version}"
    --env KUBERNETES_IMAGE_REPOSITORY=registry.k8s.io
    --env "RUNTIME=${runtime}"
    --env "RUNTIME_PACKAGE=${runtime_package}"
    --env "CRICTL_VERSION=${crictl_version}"
    --env "CNI_PLUGIN=${cni_plugin}"
    --env "CNI_MANIFEST_URL=${cni_manifest_url}"
    --env "CNI_MANIFEST_CHECKSUM=${cni_manifest_checksum}"
    --env "CNI_MANIFEST_NAME=${cni_manifest_name}"
    --env "DUFS_VERSION=${dufs_version}"
    --env "DUFS_DOWNLOAD_URL=${dufs_download_url}"
    --env "DUFS_CHECKSUM=${dufs_checksum}"
    --env "CONTROLLER_ARCH=${controller_arch}"
    --env "CONTROLLER_IMAGE_TAG=${controller_tag}"
    --env "ADDON_SPECS=${addon_specs_text}"
    --env "EXTRA_IMAGES=${extra_images_text}"
    --env "HOST_UID=$(id -u)"
    --env "HOST_GID=$(id -g)"
    --volume "${OPS_OFFLINE_STAGE_ROOT}/bundle:/bundle"
    --volume "${OPS_REPO_ROOT}/offline/builder-container.sh:/usr/local/bin/offline-builder:ro"
  )
  if [[ -n ${cni_manifest_file} ]]; then
    cni_container_file=/input/cni-manifest.yaml
    docker_args+=(
      --env "CNI_MANIFEST_FILE=${cni_container_file}"
      --volume "${cni_manifest_file}:${cni_container_file}:ro"
    )
  fi

  ops_info "启动一次性 ${base_image} 构建容器；下载时长取决于镜像数量和网络速度。"
  docker "${docker_args[@]}" "${base_image}" bash /usr/local/bin/offline-builder

  ops_offline_validate_bundle "${OPS_OFFLINE_STAGE_ROOT}/bundle" "${cni_manifest_name}"
  mkdir -p -- "$(dirname -- "${output_path}")"
  mv -- "${OPS_OFFLINE_STAGE_ROOT}/bundle" "${output_path}"
  tar -czf "${output_path}.tar.gz" -C "$(dirname -- "${output_path}")" "$(basename -- "${output_path}")"
  archive_checksum=$(ops_sha256_file "${output_path}.tar.gz")
  printf 'sha256:%s\n' "${archive_checksum}" > "${output_path}.tar.gz.sha256"

  ops_info "完整离线包制作完成：${output_path}"
  ops_info "HTTP 归档：${output_path}.tar.gz"
  ops_info "归档校验和：sha256:${archive_checksum}"
  ops_cleanup_offline_stage
  OPS_OFFLINE_STAGE_ROOT=""
  OPS_OFFLINE_CONTROLLER_TEMP_TAG=""
  trap - EXIT INT TERM
}
