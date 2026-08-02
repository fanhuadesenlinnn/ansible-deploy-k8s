# ansible-deploy-k8s

使用 Ansible 和 kubeadm 部署 Kubernetes 集群，支持单控制平面或多控制平面、containerd 或 CRI-O，以及
在线和离线安装。

## 目录结构

项目按功能边界组织，根目录的 `ops.sh` 是统一入口：

```text
.
├── ops.sh       # 统一操作入口
├── ansible/     # Ansible 配置、依赖、Inventory、Playbook 和 Role
├── docker/      # Docker 控制端镜像、Compose 配置和运行脚本
├── offline/     # 离线包制作、校验、目录模板和使用说明
├── docs/        # 项目原理及运维文档
└── scripts/     # 与部署方式无关的项目检查脚本
```

通常只需要在根目录调用 `ops.sh`；各功能目录中的脚本属于底层实现。

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

## 统一操作入口

推荐通过仓库根目录的 `ops.sh` 使用项目。不传参数时显示中文交互菜单：

```bash
./ops.sh
```

菜单按照“要完成的任务”组织。进入操作后再选择 Inventory、Docker/本机 Ansible、在线/离线模式和资源来源；
在任意输入步骤可以使用 `b` 返回主菜单，或使用 `q` 退出。无效输入不会关闭菜单，操作完成或取消后也会返回主菜单。

同一个入口可以组合本机或 Docker 执行环境，以及在线或离线安装模式：

```bash
# 使用本机 Ansible 在线部署
./ops.sh deploy -i ansible/inventories/my-cluster/hosts.yml --executor local --mode online

# 使用 Docker 中的 Ansible 在线部署
./ops.sh deploy -i ansible/inventories/my-cluster/hosts.yml --executor docker --mode online

# 先查看实际命令，不连接或修改节点
./ops.sh deploy -i ansible/inventories/my-cluster/hosts.yml --executor docker --mode online --plan
```

`ops.sh` 只是安全、统一的调度入口，底层仍调用现有 Playbook；它不会改变 Inventory 中定义的集群版本、网段、
节点地址或容器运行时。

## 快速开始

### 1. 安装控制端依赖

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r ansible/requirements.txt
ansible-galaxy collection install -r ansible/requirements.yml
```

### 2. 创建集群 Inventory

```bash
cp -R ansible/inventories/example ansible/inventories/my-cluster
$EDITOR ansible/inventories/my-cluster/hosts.yml
$EDITOR ansible/inventories/my-cluster/group_vars/all.yml
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
[`ansible/inventories/example/group_vars/all.yml`](ansible/inventories/example/group_vars/all.yml) 中。

### 3. 验证连接

```bash
./ops.sh ping -i ansible/inventories/my-cluster/hosts.yml --executor local
```

### 4. 部署集群

```bash
./ops.sh deploy -i ansible/inventories/my-cluster/hosts.yml --executor local --mode online
```

部署完成后，管理员 kubeconfig 位于 Ansible 控制端的 `ansible/artifacts/<cluster-name>.conf`。

```bash
export KUBECONFIG="$PWD/ansible/artifacts/<cluster-name>.conf"
kubectl get nodes -o wide
```

## 使用 Docker 运行

本机只安装 Docker 和 Compose 插件时，可以使用项目提供的容器化 Ansible 控制端：

```bash
cp docker/.env.example docker/.env
$EDITOR docker/.env
./ops.sh check -i ansible/inventories/example/hosts.yml --executor docker
./ops.sh deploy \
  -i ansible/inventories/my-cluster/hosts.yml \
  --executor docker \
  --mode online
```

SSH 凭据、离线文件路径和安全设置请参阅 [Docker 使用说明](docker/README.md)。

## 常用操作

### 安装可选组件

先在 `group_vars/all.yml` 的 `addons` 中启用组件，再运行：

```bash
./ops.sh addons -i ansible/inventories/my-cluster/hosts.yml --executor local
```

### 使用 crictl 排查节点

```bash
sudo crictl info
sudo crictl pods
sudo crictl ps -a
sudo crictl logs <容器 ID>
```

### 离线安装

在联网且安装了 Docker 的机器上，可以生成与目标系统和架构匹配的离线包：

```bash
./ops.sh offline-build \
  --distro ubuntu \
  --release 24.04 \
  --arch amd64 \
  --kubernetes-version 1.36.3
```

生成结果同时包含目标节点所需的 deb、crictl、dufs、Kubernetes/CNI/附加组件镜像和清单，以及断网运行
Docker Ansible 控制端所需的镜像。需要 CRI-O 或附加组件时，在制作命令中加入 `--runtime crio`、
`--addon <名称>`；部署前会严格检查离线包与 Inventory 是否匹配。

随后使用本机 Ansible 或 Docker 控制端安装：

```bash
./ops.sh deploy \
  -i ansible/inventories/my-cluster/hosts.yml \
  --executor docker \
  --mode offline \
  --bundle offline/bundles/k8s-1.36.3-ubuntu-24.04-amd64-containerd
```

离线包也可以由所有节点通过 HTTP 下载。支持范围、目录结构和自定义 CNI 方法请参阅
[离线安装说明](offline/README.md)。

### 重置集群

重置操作会删除选中主机上的 Kubernetes 和 CNI 状态。执行前请阅读[运维说明](docs/operations.md)。

## 文档

- [项目结构与执行流程](docs/project-guide.md)
- [离线安装说明](offline/README.md)
- [运维、排查与重置](docs/operations.md)
- [使用 Docker 运行](docker/README.md)
- [安全策略](SECURITY.md)

## 开发检查

```bash
pip install -r ansible/requirements-dev.txt
ansible-galaxy collection install -r ansible/requirements.yml
yamllint .
(cd ansible && ansible-lint)
bash scripts/test-ops-menu.sh
```

安装了 [just](https://github.com/casey/just) 时，也可以运行：

```bash
just check
```
