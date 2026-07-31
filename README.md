# ansible-deploy-k8s

使用 Ansible 和 kubeadm 安装标准 Kubernetes 集群。本仓库不依赖任何业务应用、私有镜像仓库、内部域名或
CI/CD 平台。

## 支持范围

- 使用 systemd 和 apt 的 Ubuntu、Debian 主机
- amd64 和 arm64 架构
- 一个或多个控制平面节点，以及任意数量的工作节点
- 默认使用 containerd，也可选择 CRI-O
- 安装固定版本的 crictl 静态二进制，并自动配置为连接所选 CRI 运行时
- 默认使用 Flannel，也可通过清单 URL 或本地文件安装其他 CNI
- 支持在线安装，以及由 Ansible 复制或通过 HTTP 服务器下载离线包
- 可选安装 metrics-server、cert-manager、Reloader 和 Istio 清单

本项目不部署业务应用、Git 服务、CI 系统、存储系统或容器镜像仓库。项目用于安装新集群和添加节点，
不支持 Kubernetes 原地升级。

## 安全特性

- 正常安装过程绝不会执行 `kubeadm reset`。
- 已存在 `/etc/kubernetes/admin.conf` 或 `/etc/kubernetes/kubelet.conf` 时，不会重复初始化或加入节点。
- 破坏性的重置操作独立放在 `playbooks/reset.yml` 中，必须同时提供布尔确认值和集群名称。
- 仓库中不存放真实凭据或生产环境 Inventory。
- 默认不会扩大 NodePort 范围，也不会覆盖操作系统的软件包镜像源。

## 快速开始

Ansible 控制端要求：

- Python 3.10+
- Ansible Core 2.16+
- 能够通过 SSH 访问所有目标主机
- 免密 sudo，或通过安全方式提供 Ansible 提权密码

安装控制端依赖：

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

复制示例 Inventory，并替换其中仅用于文档演示的地址：

```bash
cp -R inventories/example inventories/my-cluster
$EDITOR inventories/my-cluster/hosts.yml
$EDITOR inventories/my-cluster/group_vars/all.yml
```

除示例以外的 Inventory 目录均会被 Git 忽略，以降低误提交生产地址或敏感信息的风险。

验证连通性并安装集群：

```bash
ansible -i inventories/my-cluster/hosts.yml k8s_cluster -m ansible.builtin.ping
ansible-playbook -i inventories/my-cluster/hosts.yml playbooks/site.yml
```

管理员 kubeconfig 会写入 Ansible 控制端的 `artifacts/<cluster-name>.conf`。

## Inventory 结构

`kube_control_plane` 组中的第一台主机负责初始化集群，其余主机作为控制平面节点加入。所有主机还必须是
`k8s_cluster` 的子节点；示例 Inventory 已自动建立这一关系。

```yaml
all:
  children:
    kube_control_plane:
      hosts:
        control-01:
          ansible_host: 192.0.2.10
    kube_workers:
      hosts:
        worker-01:
          ansible_host: 192.0.2.11
    k8s_cluster:
      children:
        kube_control_plane: {}
        kube_workers: {}
```

使用多个控制平面节点时，请将 `control_plane_endpoint` 设置为稳定的负载均衡器地址或虚拟 IP。本项目
不会创建该负载均衡器。

## 在线与离线安装

在线模式使用 Kubernetes 和 CRI-O 官方软件源，以及配置的 CNI 清单 URL：

```yaml
install_mode: online
```

离线模式可以使用控制端上的本地离线包目录，也可以使用 HTTP 托管的 tar 归档：

```yaml
install_mode: offline
offline_bundle_path: /absolute/path/on/ansible-controller/k8s-offline-bundle
# 或者：
# offline_bundle_url: http://artifact-server.example/k8s-offline-bundle.tar.gz
# offline_bundle_checksum: sha256:<归档校验和>
```

解压后的离线包必须包含 `packages/*.deb`、`images/*.tar`、`manifests/<CNI 文件>`；启用 crictl 安装时，
还必须包含 `bin/crictl`。任意 HTTP 服务器都可以托管该归档，也可通过 `playbooks/artifact-server.yml`
安装可选的 dufs 辅助服务。

完整目录结构请参阅[离线安装文档](docs/offline-installation.md)。

## 使用 crictl 排查节点

默认以校验和验证过的静态二进制形式安装 crictl，并生成 `/etc/crictl.yaml`。它与 kubeadm 共用
`kubernetes_cri_socket`，因此会自动连接 containerd 或 CRI-O：

```bash
sudo crictl info
sudo crictl pods
sudo crictl ps -a
sudo crictl images
sudo crictl logs <容器 ID>
```

设置 `install_crictl: false` 可以跳过安装。`crictl_version` 应与 Kubernetes 保持相同的主版本号和次版本号；
修改固定的 crictl 版本时，必须同时更新两种架构的校验和。

## 可选附加组件

附加组件默认关闭，需单独启用对应变量：

```yaml
addons:
  metrics_server: true
  cert_manager: false
  reloader: false
  istio: false
```

也可以独立运行附加组件 Playbook：

```bash
ansible-playbook -i inventories/my-cluster/hosts.yml playbooks/addons.yml
```

## 重置集群

重置操作具有破坏性，因此与安装流程完全分离：

```bash
ansible-playbook -i inventories/my-cluster/hosts.yml playbooks/reset.yml \
  -e kubernetes_reset_confirm=true \
  -e kubernetes_reset_cluster_name=my-cluster-name
```

执行前请先检查该 Playbook。它会从指定主机删除 kubeadm 状态和 CNI 网络配置，同时删除各主机上的 root
kubeconfig 以及导出到控制端的 kubeconfig。根据 kubeadm 的设计，reset 不会清理 iptables、nftables 或
IPVS 规则；如果需要完全还原主机，请另行清理这些规则。

## 已有集群与升级

`playbooks/site.yml` 仅用于安装和横向扩容。对于已经配置的节点，它会检查已安装 kubelet 的补丁版本是否
与 `kubernetes_version` 一致；如果不一致，会在修改软件包之前失败。升级集群时请遵循 kubeadm 官方升级流程，
仅修改 `kubernetes_version` 并不能完成升级。

集群初始化完成后，应将容器运行时、Pod/Service CIDR 和控制平面端点视为不可变配置，除非正在执行专门的
Kubernetes 迁移或重新配置流程。

## 主要变量

所有有文档说明的默认值都位于 `inventories/example/group_vars/all.yml`。重要变量包括：

- `kubernetes_version` 和 `kubernetes_version_minor`
- `container_runtime`
- `install_crictl` 和 `crictl_version`
- `pod_network_cidr` 和 `service_cidr`
- `control_plane_endpoint`
- `api_server_cert_sans`
- `cni_manifest_url` 或 `cni_manifest_file`
- `cni_manifest_checksum`
- `install_mode`
- `offline_bundle_checksum`
- `registry_mirrors`
- `proxy_env`
- `kubernetes_apply_force_conflicts`（默认关闭）

## 验证

```bash
pip install -r requirements-dev.txt
yamllint .
ansible-lint
just check
```
