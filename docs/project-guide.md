# 项目结构与执行流程

本文面向需要阅读、维护或扩展本项目的人。第一次部署集群时，先按照仓库根目录的 README 操作即可。

## 建议阅读顺序

1. `ansible/inventories/example/hosts.yml`：理解控制平面、工作节点和全集群主机组。
2. `ansible/inventories/example/group_vars/all.yml`：查看所有可配置变量及默认行为。
3. `ansible/playbooks/site.yml`：了解各部署阶段的调用顺序。
4. `ansible/roles/<名称>/tasks/main.yml`：定位某个阶段的具体任务。
5. `ansible/roles/<名称>/templates/`：查看最终写入目标主机的配置格式。

环境差异应优先通过 Inventory 变量表达，不要为每个环境复制或直接修改 Role 任务。

## 目录职责

| 路径 | 用途 |
| --- | --- |
| `ops.sh` | 用户唯一需要记住的操作入口，负责把命令分发到各功能目录。 |
| `ansible/` | Ansible 配置、依赖、Inventory、Playbook、Role 和命令实现。 |
| `ansible/ansible.cfg` | 项目级 Ansible 默认设置和 SSH 连接行为。 |
| `ansible/inventories/example/` | 示例主机分组、连接参数和集群变量。 |
| `ansible/playbooks/` | 集群安装、附加组件、制品服务和重置入口。 |
| `ansible/roles/` | 每个部署阶段的具体任务、模板及 Handler。 |
| `docker/` | 容器化 Ansible 控制端的镜像、Compose 配置和运行脚本。 |
| `offline/` | 离线包制作、校验、构建容器脚本、目录模板和使用说明。 |
| `offline/defaults.yml` | 离线包制作专用的版本、下载地址和校验值；不读取集群 Inventory。 |
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

`ansible/playbooks/site.yml` 按以下顺序执行：

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
| `ansible/artifacts/<cluster-name>.conf` | Ansible 控制端 | 导出的管理员 kubeconfig。 |

每个 Role 的输入、输出和关键判断也写在对应任务文件开头及复杂任务附近。
