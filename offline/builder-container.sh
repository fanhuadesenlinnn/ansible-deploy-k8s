#!/usr/bin/env bash
# 本脚本只在 ops.sh 创建的一次性 Ubuntu/Debian 容器中运行。
# 它为目标系统解析 deb 依赖，下载 crictl、CNI 清单和指定架构的 OCI 镜像归档。
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

required_env=(
  TARGET_DISTRO TARGET_RELEASE TARGET_ARCH KUBERNETES_VERSION
  KUBERNETES_PACKAGE_VERSION KUBERNETES_IMAGE_REPOSITORY RUNTIME
  RUNTIME_PACKAGE CRICTL_VERSION CNI_PLUGIN CNI_MANIFEST_URL
  CNI_MANIFEST_CHECKSUM CNI_MANIFEST_NAME HOST_UID HOST_GID
)

for variable_name in "${required_env[@]}"; do
  if [[ -z ${!variable_name:-} ]]; then
    echo "缺少构建变量：${variable_name}" >&2
    exit 1
  fi
done

mkdir -p /bundle/bin /bundle/packages /bundle/images /bundle/manifests

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
curl --fail --silent --show-error --location \
  "${CNI_MANIFEST_URL}" --output "/bundle/manifests/${CNI_MANIFEST_NAME}"
cni_expected_checksum=${CNI_MANIFEST_CHECKSUM#sha256:}
printf '%s  %s\n' \
  "${cni_expected_checksum}" "/bundle/manifests/${CNI_MANIFEST_NAME}" \
  | sha256sum --check

echo "获取 Kubernetes ${KUBERNETES_VERSION} 和 containerd 镜像列表……"
apt-get install --yes --no-install-recommends \
  "kubeadm=${KUBERNETES_PACKAGE_VERSION}" \
  "${RUNTIME_PACKAGE}"
kubeadm config images list \
  --kubernetes-version "v${KUBERNETES_VERSION}" \
  --image-repository "${KUBERNETES_IMAGE_REPOSITORY}" \
  > /tmp/kubernetes-images.txt

# Pod sandbox 镜像由容器运行时决定，不一定与 kubeadm 镜像列表中的
# pause 版本一致。直接读取目标发行版的 containerd 默认配置，避免严格离线
# 安装时才发现缺少 sandbox 镜像。containerd 1.x 使用 sandbox_image，2.x 使用 sandbox。
runtime_sandbox_image=$(
  containerd config default \
    | sed -nE "s/^[[:space:]]*(sandbox_image|sandbox)[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"].*/\2/p" \
    | head -n 1
)
if [[ -z ${runtime_sandbox_image} ]]; then
  echo "无法从 containerd 默认配置读取 Pod sandbox 镜像。" >&2
  exit 1
fi
printf '%s\n' "${runtime_sandbox_image}" > /tmp/runtime-images.txt
echo "containerd Pod sandbox 镜像：${runtime_sandbox_image}"

awk '$1 == "image:" {print $2}' \
  "/bundle/manifests/${CNI_MANIFEST_NAME}" \
  | tr -d "\"'" \
  > /tmp/cni-images.txt
printf '%s\n' "${EXTRA_IMAGES:-}" \
  | awk 'NF > 0 {print $1}' \
  > /tmp/extra-images.txt
cat /tmp/kubernetes-images.txt /tmp/runtime-images.txt /tmp/cni-images.txt /tmp/extra-images.txt \
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
  printf "format_version: '1'\n"
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
  printf 'package_count: %s\n' "${package_count}"
  printf 'image_count: %s\n' "${image_count}"
  printf '%s\n' 'images:'
  while IFS= read -r image_reference; do
    printf "  - '%s'\n" "${image_reference}"
  done < /tmp/all-images.txt
} > /bundle/metadata.yml

(
  cd /bundle
  find bin packages images manifests -type f -print \
    | sort \
    | while IFS= read -r bundle_file; do
        sha256sum "${bundle_file}"
      done
  sha256sum metadata.yml
) > /bundle/SHA256SUMS

chown -R "${HOST_UID}:${HOST_GID}" /bundle
echo "离线包内容制作完成：${package_count} 个 deb，${image_count} 个镜像归档。"
