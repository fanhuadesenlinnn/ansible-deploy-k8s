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
while IFS= read -r package_name; do
  case "${package_name}" in
    kubeadm|kubelet|kubectl) continue ;;
  esac

  if apt-cache show "${package_name}" >/dev/null 2>&1; then
    apt-get download "${package_name}"
  else
    echo "跳过没有直接候选版本的虚拟软件包：${package_name}"
  fi
done < /tmp/offline-package-names.txt

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

echo "获取 Kubernetes ${KUBERNETES_VERSION} 镜像列表……"
apt-get install --yes --no-install-recommends "kubeadm=${KUBERNETES_PACKAGE_VERSION}"
kubeadm config images list \
  --kubernetes-version "v${KUBERNETES_VERSION}" \
  --image-repository "${KUBERNETES_IMAGE_REPOSITORY}" \
  > /tmp/kubernetes-images.txt

awk '$1 == "image:" {print $2}' \
  "/bundle/manifests/${CNI_MANIFEST_NAME}" \
  | tr -d "\"'" \
  > /tmp/cni-images.txt
printf '%s\n' "${EXTRA_IMAGES:-}" \
  | awk 'NF > 0 {print $1}' \
  > /tmp/extra-images.txt
cat /tmp/kubernetes-images.txt /tmp/cni-images.txt /tmp/extra-images.txt \
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
    "oci-archive:/bundle/images/${archive_name}.tar"
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
