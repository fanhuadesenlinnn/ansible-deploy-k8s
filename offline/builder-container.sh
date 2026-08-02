#!/usr/bin/env bash
# 本脚本只在 ops.sh 创建的一次性 Ubuntu/Debian 容器中运行。
# 它为目标系统解析 deb 依赖，下载运行时、crictl、dufs、CNI/附加组件清单和
# 指定架构的 OCI 镜像归档。控制端 Ansible 镜像由外层 ops.sh 预先放入 bundle/controller/。
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

required_env=(
  TARGET_DISTRO TARGET_RELEASE TARGET_ARCH KUBERNETES_VERSION
  KUBERNETES_PACKAGE_VERSION KUBERNETES_IMAGE_REPOSITORY RUNTIME
  RUNTIME_PACKAGE CRICTL_VERSION CNI_PLUGIN
  CNI_MANIFEST_CHECKSUM CNI_MANIFEST_NAME DUFS_VERSION DUFS_DOWNLOAD_URL
  DUFS_CHECKSUM CONTROLLER_ARCH CONTROLLER_IMAGE_TAG HOST_UID HOST_GID
)

for variable_name in "${required_env[@]}"; do
  if [[ -z ${!variable_name:-} ]]; then
    echo "缺少构建变量：${variable_name}" >&2
    exit 1
  fi
done

if [[ -z ${CNI_MANIFEST_URL:-} && -z ${CNI_MANIFEST_FILE:-} ]]; then
  echo "CNI_MANIFEST_URL 与 CNI_MANIFEST_FILE 必须提供一个。" >&2
  exit 1
fi

mkdir -p /bundle/bin /bundle/packages /bundle/images /bundle/manifests/addons /bundle/controller

apt-get update
apt-get install --yes --no-install-recommends \
  apt-rdepends \
  ca-certificates \
  curl \
  gnupg \
  skopeo \
  tar

kubernetes_minor="v${KUBERNETES_VERSION%.*}"
install -d -m 0755 /etc/apt/keyrings
curl --fail --silent --show-error --location \
  "https://pkgs.k8s.io/core:/stable:/${kubernetes_minor}/deb/Release.key" \
  | gpg --dearmor --yes --output /etc/apt/keyrings/kubernetes.gpg
printf '%s\n' \
  "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/${kubernetes_minor}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

# CRI-O 使用与 Kubernetes 相同的主次版本软件源。容器内只用该源解析和下载
# 目标节点软件包，真正部署时不再访问它。
if [[ ${RUNTIME} == crio ]]; then
  curl --fail --silent --show-error --location \
    "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${kubernetes_minor}/deb/Release.key" \
    | gpg --dearmor --yes --output /etc/apt/keyrings/cri-o.gpg
  printf '%s\n' \
    "deb [signed-by=/etc/apt/keyrings/cri-o.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${kubernetes_minor}/deb/ /" \
    > /etc/apt/sources.list.d/cri-o.list
fi
apt-get update

base_packages=(
  apt-transport-https
  ca-certificates
  conntrack
  curl
  gpg
  gzip
  iptables
  socat
  tar
  "${RUNTIME_PACKAGE}"
  kubeadm
  kubelet
  kubectl
)

# podman load 用于把 OCI 归档导入 CRI-O 共用的 containers/storage。
# Ubuntu 中 Podman 依赖虚拟包 container-network-stack；显式选择它的实际
# 提供者，避免 apt-rdepends 只记录虚拟包、离线节点因无法解析提供者而失败。
if [[ ${RUNTIME} == crio ]]; then
  base_packages+=(podman containernetworking-plugins)
fi

echo "解析目标系统的软件包依赖……"
apt-rdepends "${base_packages[@]}" 2>/dev/null \
  | awk '/^[^ ]/ {print $1}' \
  | sort -u > /tmp/offline-package-names.txt

cd /bundle/packages
download_packages=()
while IFS= read -r package_name; do
  candidate_version=""
  case "${package_name}" in
    kubeadm|kubelet|kubectl) continue ;;
  esac

  # apt-rdepends 会输出 debconf-2.0 等虚拟包。apt-cache show 对部分虚拟包仍会
  # 返回成功，但 apt-get download 无法下载它们；只有存在实际候选版本时才下载。
  candidate_version=$(apt-cache policy "${package_name}" \
    | awk '/Candidate:/ {print $2; exit}')
  if [[ -n ${candidate_version} && ${candidate_version} != '(none)' ]]; then
    download_packages+=("${package_name}=${candidate_version}")
  else
    echo "跳过没有直接候选版本的虚拟软件包：${package_name}"
  fi
done < /tmp/offline-package-names.txt

# 一次提交全部依赖，避免为每个软件包重复建立软件源连接。
if [[ ${#download_packages[@]} -gt 0 ]]; then
  apt-get download "${download_packages[@]}"
fi

apt-get download \
  "kubeadm=${KUBERNETES_PACKAGE_VERSION}" \
  "kubelet=${KUBERNETES_PACKAGE_VERSION}" \
  "kubectl=${KUBERNETES_PACKAGE_VERSION}"

echo "下载并校验 crictl ${CRICTL_VERSION}……"
crictl_archive="crictl-${CRICTL_VERSION}-linux-${TARGET_ARCH}.tar.gz"
crictl_url="https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/${crictl_archive}"
curl --fail --silent --show-error --location "${crictl_url}" --output "/tmp/${crictl_archive}"
curl --fail --silent --show-error --location "${crictl_url}.sha256" --output /tmp/crictl.sha256
crictl_expected_checksum=$(awk '{print $1}' /tmp/crictl.sha256)
printf '%s  %s\n' "${crictl_expected_checksum}" "/tmp/${crictl_archive}" | sha256sum --check
tar -xzf "/tmp/${crictl_archive}" -C /bundle/bin crictl
chmod 0755 /bundle/bin/crictl

echo "下载并校验 ${CNI_PLUGIN} 清单……"
if [[ -n ${CNI_MANIFEST_FILE:-} ]]; then
  cp -- "${CNI_MANIFEST_FILE}" "/bundle/manifests/${CNI_MANIFEST_NAME}"
else
  curl --fail --silent --show-error --location \
    "${CNI_MANIFEST_URL}" --output "/bundle/manifests/${CNI_MANIFEST_NAME}"
fi
cni_expected_checksum=${CNI_MANIFEST_CHECKSUM#sha256:}
printf '%s  %s\n' \
  "${cni_expected_checksum}" "/bundle/manifests/${CNI_MANIFEST_NAME}" \
  | sha256sum --check

echo "下载并校验 dufs ${DUFS_VERSION}……"
dufs_archive="dufs-${DUFS_VERSION}-${TARGET_ARCH}.tar.gz"
curl --fail --silent --show-error --location \
  "${DUFS_DOWNLOAD_URL}" --output "/tmp/${dufs_archive}"
dufs_expected_checksum=${DUFS_CHECKSUM#sha256:}
printf '%s  %s\n' "${dufs_expected_checksum}" "/tmp/${dufs_archive}" | sha256sum --check
tar -xzf "/tmp/${dufs_archive}" -C /bundle/bin dufs
chmod 0755 /bundle/bin/dufs

echo "下载并校验已选附加组件清单……"
: > /tmp/addons.txt
while IFS='|' read -r addon_name addon_url addon_checksum; do
  [[ -n ${addon_name} ]] || continue
  addon_manifest="/bundle/manifests/addons/${addon_name}.yaml"
  curl --fail --silent --show-error --location "${addon_url}" --output "${addon_manifest}"
  addon_expected_checksum=${addon_checksum#sha256:}
  printf '%s  %s\n' "${addon_expected_checksum}" "${addon_manifest}" | sha256sum --check
  printf '%s\n' "${addon_name}" >> /tmp/addons.txt
done <<< "${ADDON_SPECS:-}"

echo "获取 Kubernetes ${KUBERNETES_VERSION} 和 ${RUNTIME} 镜像列表……"
runtime_install_packages=("${RUNTIME_PACKAGE}")
if [[ ${RUNTIME} == crio ]]; then
  runtime_install_packages+=(podman containernetworking-plugins)
fi
apt-get install --yes --no-install-recommends \
  "kubeadm=${KUBERNETES_PACKAGE_VERSION}" \
  "${runtime_install_packages[@]}"
kubeadm config images list \
  --kubernetes-version "v${KUBERNETES_VERSION}" \
  --image-repository "${KUBERNETES_IMAGE_REPOSITORY}" \
  > /tmp/kubernetes-images.txt

# Pod sandbox 镜像由容器运行时决定，不一定与 kubeadm 镜像列表中的 pause
# 版本一致。直接读取目标运行时默认配置，两个版本都打包。
if [[ ${RUNTIME} == containerd ]]; then
  runtime_sandbox_image=$(
    containerd config default \
      | sed -nE "s/^[[:space:]]*(sandbox_image|sandbox)[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"].*/\2/p" \
      | head -n 1
  )
else
  runtime_sandbox_image=$(
    crio config \
      | sed -nE 's/^[[:space:]#]*pause_image[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
      | head -n 1
  )
fi
if [[ -z ${runtime_sandbox_image} ]]; then
  echo "无法从 ${RUNTIME} 默认配置读取 Pod sandbox 镜像。" >&2
  exit 1
fi
printf '%s\n' "${runtime_sandbox_image}" > /tmp/runtime-images.txt
echo "${RUNTIME} Pod sandbox 镜像：${runtime_sandbox_image}"

# CNI 和附加组件必须使用最终渲染后、image: 字段中包含完整引用的 YAML。
# 动态生成的隐式镜像需要通过 --extra-image 显式加入。
find /bundle/manifests -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 \
  | xargs -0 sed -nE \
      "s/^[[:space:]-]*image:[[:space:]]*[\"']?([^\"'[:space:]#]+).*/\\1/p" \
  > /tmp/manifest-images.txt
printf '%s\n' "${EXTRA_IMAGES:-}" \
  | awk 'NF > 0 {print $1}' \
  > /tmp/extra-images.txt
cat /tmp/kubernetes-images.txt /tmp/runtime-images.txt /tmp/manifest-images.txt /tmp/extra-images.txt \
  | awk 'NF > 0' \
  | sort -u > /tmp/all-images.txt

echo "下载目标架构镜像并保存为 OCI 归档……"
while IFS= read -r image_reference; do
  archive_name=$(printf '%s' "${image_reference}" | tr '/:@' '____')
  echo "保存镜像：${image_reference}"
  skopeo copy \
    --retry-times 3 \
    --override-os linux \
    --override-arch "${TARGET_ARCH}" \
    "docker://${image_reference}" \
    "oci-archive:/bundle/images/${archive_name}.tar:${image_reference}"
done < /tmp/all-images.txt

package_count=$(find /bundle/packages -maxdepth 1 -type f -name '*.deb' | wc -l | tr -d ' ')
image_count=$(find /bundle/images -maxdepth 1 -type f -name '*.tar' | wc -l | tr -d ' ')
created_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

{
  printf '%s\n' '---'
  printf "format_version: '2'\n"
  printf "complete_bundle: true\n"
  printf "created_at: '%s'\n" "${created_at}"
  printf "target_distro: '%s'\n" "${TARGET_DISTRO}"
  printf "target_release: '%s'\n" "${TARGET_RELEASE}"
  printf "target_arch: '%s'\n" "${TARGET_ARCH}"
  printf "kubernetes_version: '%s'\n" "${KUBERNETES_VERSION}"
  printf "kubernetes_package_version: '%s'\n" "${KUBERNETES_PACKAGE_VERSION}"
  printf "container_runtime: '%s'\n" "${RUNTIME}"
  printf "container_runtime_package: '%s'\n" "${RUNTIME_PACKAGE}"
  printf "runtime_sandbox_image: '%s'\n" "${runtime_sandbox_image}"
  printf "crictl_version: '%s'\n" "${CRICTL_VERSION}"
  printf "cni_plugin: '%s'\n" "${CNI_PLUGIN}"
  printf "cni_manifest: '%s'\n" "${CNI_MANIFEST_NAME}"
  printf "dufs_version: '%s'\n" "${DUFS_VERSION}"
  printf "controller_arch: '%s'\n" "${CONTROLLER_ARCH}"
  printf "controller_image_archive: 'controller/ansible-controller-image.tar'\n"
  printf "controller_image_tag: '%s'\n" "${CONTROLLER_IMAGE_TAG}"
  printf 'package_count: %s\n' "${package_count}"
  printf 'image_count: %s\n' "${image_count}"
  printf '%s\n' 'addons:'
  while IFS= read -r addon_name; do
    [[ -n ${addon_name} ]] && printf "  - '%s'\n" "${addon_name}"
  done < /tmp/addons.txt
  printf '%s\n' 'images:'
  while IFS= read -r image_reference; do
    printf "  - '%s'\n" "${image_reference}"
  done < /tmp/all-images.txt
} > /bundle/metadata.yml

(
  cd /bundle
  find bin packages images manifests controller -type f -print \
    | sort \
    | while IFS= read -r bundle_file; do
        sha256sum "${bundle_file}"
      done
  sha256sum metadata.yml
) > /bundle/SHA256SUMS

chown -R "${HOST_UID}:${HOST_GID}" /bundle
echo "离线包内容制作完成：${package_count} 个 deb，${image_count} 个镜像归档。"
