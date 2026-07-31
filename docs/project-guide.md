# 项目结构与执行流程

本文面向需要阅读、维护或扩展本项目的人。第一次部署集群时，先按照仓库根目录的 README 操作即可。

## 建议阅读顺序

1. `inventories/example/hosts.yml`：理解控制平面、工作节点和全集群主机组。
2. `inventories/example/group_vars/all.yml`：查看所有可配置变量及默认行为。
3. `playbooks/site.yml`：了解各部署阶段的调用顺序。
4. `roles/<名称>/tasks/main.yml`：定位某个阶段的具体任务。
5. `roles/<名称>/templates/`：查看最终写入目标主机的配置格式。

环境差异应优先通过 Inventory 变量表达，不要为每个环境复制或直接修改 Role 任务。

## 目录职责

| 路径 | 用途 |
| --- | --- |
| `ansible.cfg` | 项目级 Ansible 默认设置和 SSH 连接行为。 |
| `inventories/example/hosts.yml` | 示例主机分组和连接参数。 |
| `inventories/example/group_vars/all.yml` | 集群的主要配置入口。 |
| `playbooks/site.yml` | 安装和添加节点的主入口。 |
| `playbooks/addons.yml` | 独立安装或更新可选组件。 |
| `playbooks/artifact-server.yml` | 可选安装只读 dufs 离线制品服务。 |
| `playbooks/reset.yml` | 需要显式确认的集群重置入口。 |
| `roles/preflight/` | 检查系统、架构、变量和已有节点状态。 |
| `roles/artifact_bundle/` | 准备和校验离线资源。 |
| `roles/os_prepare/` | 安装基础工具、关闭 Swap、加载模块并设置 sysctl。 |
| `roles/container_runtime/` | 安装和配置 containerd 或 CRI-O。 |
| `roles/crictl/` | 安装 crictl 并配置 CRI Socket。 |
| `roles/kubernetes_packages/` | 安装和锁定 kubeadm、kubelet、kubectl。 |
| `roles/control_plane/` | 初始化和扩展控制平面。 |
| `roles/cni/` | 应用 CNI 清单并等待 CoreDNS。 |
| `roles/worker/` | 将工作节点加入集群。 |
| `roles/kubeconfig/` | 将管理员 kubeconfig 导出到控制端。 |
| `roles/addons/` | 管理可选 Kubernetes 组件。 |
| `docker/` | 无需在宿主机安装 Python/Ansible 的容器化控制端环境。 |
| `ops.sh`、`ops/` | 统一操作入口及在线、离线、本机、Docker 调度和离线包制作逻辑。 |
| `files/offline-bundle/` | 离线包目录结构占位符。 |
| `scripts/` | 本地和 CI 共用的检查脚本。 |
| `.github/` | GitHub Actions 和依赖更新配置。 |

## Inventory 关系

`kube_control_plane` 保存控制平面节点，`kube_workers` 保存工作节点。两个组同时作为 `k8s_cluster` 的子组，
使公共准备任务能够在所有 Kubernetes 节点上运行。

`kube_control_plane` 中的第一台主机负责执行 `kubeadm init`。其他控制平面节点和工作节点使用它在本次运行时
生成的临时加入命令进入集群。

变量通常从 `group_vars/all.yml` 读取，也可以由 `host_vars` 或命令行 `-e` 覆盖。命令行变量优先级较高，
生产操作前应确认传入值与目标 Inventory 一致。

## 主部署流程

`playbooks/site.yml` 按以下顺序执行：

```text
验证 Inventory 和网络 CIDR
  → 检查目标主机和已有 Kubernetes 状态
  → 准备在线或离线资源
  → 准备操作系统
  → 安装容器运行时和 crictl
  → 安装 Kubernetes 软件包
  → 初始化或扩展控制平面
  → 安装 CNI
  → 加入工作节点
  → 导出管理员 kubeconfig
  → 等待全部节点 Ready
```

控制平面使用 `serial: 1` 逐台处理。CNI、kubeconfig 导出和最终节点检查只在第一台控制平面节点执行。

## 重复执行

项目使用稳定文件判断节点状态：

| 文件 | 含义 |
| --- | --- |
| `/etc/kubernetes/admin.conf` | 当前控制平面节点已经初始化或加入。 |
| `/etc/kubernetes/kubelet.conf` | 当前工作节点已经加入集群。 |
| `/var/lib/kubelet/instance-config.yaml` | kubelet 当前使用的 CRI Socket。 |

这些文件存在时，对应的 `kubeadm init` 或 `kubeadm join` 会被跳过。配置模板、软件包和 systemd 服务仍会按
Ansible 的幂等规则检查并收敛到当前配置。

## 主要输出

| 位置 | 所在机器 | 用途 |
| --- | --- | --- |
| `/etc/containerd/config.toml` | containerd 节点 | containerd 主配置。 |
| `/etc/containerd/certs.d/` | containerd 节点 | 逐镜像仓库 endpoint 和 TLS 配置。 |
| `/etc/crictl.yaml` | Kubernetes 节点 | crictl 的 CRI Socket 和请求参数。 |
| `/etc/kubernetes/kubeadm-init.yaml` | 第一台控制平面节点 | 渲染后的 kubeadm 初始化配置。 |
| `/etc/kubernetes/admin.conf` | 控制平面节点 | 管理员 kubeconfig。 |
| `/etc/kubernetes/cni-manifest.yaml` | 第一台控制平面节点 | 最终应用的 CNI 清单副本。 |
| `artifacts/<cluster-name>.conf` | Ansible 控制端 | 导出的管理员 kubeconfig。 |

每个 Role 的输入、输出和关键判断也写在对应任务文件开头及复杂任务附近。
