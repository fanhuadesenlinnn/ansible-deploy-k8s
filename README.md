# ansible-deploy-k8s

使用 Ansible 和 kubeadm 部署 Kubernetes 集群，支持单控制平面或多控制平面、containerd 或 CRI-O，以及
在线和离线安装。

## 功能与支持

- 目标系统：使用 systemd 和 apt 的 Ubuntu、Debian
- CPU 架构：amd64、arm64
- 容器运行时：containerd（默认）或 CRI-O
- CNI：默认使用 Flannel，也可提供其他 CNI 的清单 URL 或本地文件
- 节点工具：默认安装并配置 crictl
- 可选组件：metrics-server、cert-manager、Reloader、Istio 自定义清单

## 环境要求

Ansible 控制端：

- Python 3.10+
- Ansible Core 2.16+
- 能够通过 SSH 访问所有目标主机

目标主机：

- 支持的 Ubuntu 或 Debian 版本
- 可使用 sudo 获取 root 权限
- 主机名、IP 地址和节点间网络已经配置完成
- 多控制平面集群已经准备好负载均衡器或虚拟 IP

## 快速开始

### 1. 安装控制端依赖

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

### 2. 创建集群 Inventory

```bash
cp -R inventories/example inventories/my-cluster
$EDITOR inventories/my-cluster/hosts.yml
$EDITOR inventories/my-cluster/group_vars/all.yml
```

首次部署至少需要确认这些配置：

| 配置 | 作用 |
| --- | --- |
| `ansible_host`、`ansible_user` | Ansible 连接目标主机的地址和 SSH 用户。 |
| `cluster_name` | 集群名称和导出 kubeconfig 的文件名。 |
| `kubernetes_version` | 要安装的 Kubernetes 完整版本。 |
| `container_runtime` | 选择 `containerd` 或 `crio`。 |
| `pod_network_cidr`、`service_cidr` | Pod 和 Service 网段，两者不能重叠。 |
| `control_plane_endpoint` | 多控制平面集群使用的负载均衡器或 VIP 入口。 |
| `install_mode` | 选择 `online` 或 `offline`。 |

所有变量的用途和注意事项都写在
[`inventories/example/group_vars/all.yml`](inventories/example/group_vars/all.yml) 中。

### 3. 验证连接

```bash
ansible -i inventories/my-cluster/hosts.yml k8s_cluster -m ansible.builtin.ping
```

### 4. 部署集群

```bash
ansible-playbook -i inventories/my-cluster/hosts.yml playbooks/site.yml
```

部署完成后，管理员 kubeconfig 位于 Ansible 控制端的 `artifacts/<cluster-name>.conf`。

```bash
export KUBECONFIG="$PWD/artifacts/<cluster-name>.conf"
kubectl get nodes -o wide
```

## 常用操作

### 安装可选组件

先在 `group_vars/all.yml` 的 `addons` 中启用组件，再运行：

```bash
ansible-playbook -i inventories/my-cluster/hosts.yml playbooks/addons.yml
```

### 使用 crictl 排查节点

```bash
sudo crictl info
sudo crictl pods
sudo crictl ps -a
sudo crictl logs <容器 ID>
```

### 离线安装

离线包支持从 Ansible 控制端复制，也可以由所有节点通过 HTTP 下载。目录结构和配置方式请参阅
[离线安装说明](docs/offline-installation.md)。

### 重置集群

重置操作会删除选中主机上的 Kubernetes 和 CNI 状态。执行前请阅读[运维说明](docs/operations.md)。

## 文档

- [项目结构与执行流程](docs/project-guide.md)
- [离线安装说明](docs/offline-installation.md)
- [运维、排查与重置](docs/operations.md)
- [安全策略](SECURITY.md)

## 开发检查

```bash
pip install -r requirements-dev.txt
ansible-galaxy collection install -r requirements.yml
yamllint .
ansible-lint
```

安装了 [just](https://github.com/casey/just) 时，也可以运行：

```bash
just check
```
