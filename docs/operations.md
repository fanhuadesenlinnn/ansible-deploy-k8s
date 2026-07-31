# 运维、排查与重置

## 统一操作入口

推荐使用根目录的 `ops.sh` 执行常见操作：

```bash
./ops.sh check -i inventories/my-cluster/hosts.yml --executor docker
./ops.sh ping -i inventories/my-cluster/hosts.yml --executor docker
./ops.sh deploy -i inventories/my-cluster/hosts.yml --executor docker --mode online
./ops.sh addons -i inventories/my-cluster/hosts.yml --executor docker
```

所有部署命令都会先显示执行环境、安装模式、Inventory、资源来源和底层命令。人工操作需要再次确认；自动化环境
必须显式传入 `--yes`。使用 `--plan` 只显示部署命令，不连接或修改节点。

本机已安装 Ansible 时使用 `--executor local`；本机只安装 Docker 时使用 `--executor docker`。两种方式调用相同
Playbook，不会产生两套部署逻辑。

## 适用操作

`playbooks/site.yml` 用于安装新集群和添加节点。它不会执行 Kubernetes 版本升级，也不会迁移已经加入集群的
节点所使用的容器运行时。

对于已有节点，预检会确认：

- kubelet 版本与 `kubernetes_version` 一致；
- 当前 CRI Socket 与 `container_runtime` 对应；
- 多控制平面集群配置了稳定的 `control_plane_endpoint`。

## 初始化后不应直接修改的配置

以下配置参与集群身份或网络初始化，不能仅通过重新运行安装 Playbook 完成迁移：

- `kubernetes_version`
- `container_runtime` 和 `kubernetes_cri_socket`
- `pod_network_cidr`、`service_cidr`、`cluster_dns_domain`
- `control_plane_endpoint`

升级 Kubernetes 时应按照 kubeadm 的版本升级流程逐个小版本操作。迁移容器运行时或集群网段时，应单独制定
节点排空、组件重配置和回滚方案。

## 常用检查

在 Ansible 控制端检查集群：

```bash
export KUBECONFIG="$PWD/artifacts/<cluster-name>.conf"
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
kubectl get events --all-namespaces --sort-by=.lastTimestamp
```

在异常节点检查服务：

```bash
sudo systemctl status kubelet
sudo systemctl status containerd  # 使用 CRI-O 时改为 crio
sudo journalctl -u kubelet -n 200 --no-pager
```

使用 crictl 检查 CRI：

```bash
sudo crictl info
sudo crictl pods
sudo crictl ps -a
sudo crictl images
sudo crictl logs <容器 ID>
```

`/etc/crictl.yaml` 已指向当前配置的 containerd 或 CRI-O Socket，通常不需要额外传入 endpoint 参数。

## kubeconfig

管理员 kubeconfig 默认导出到 `artifacts/<cluster-name>.conf`，文件权限为 `0600`。该文件拥有集群管理员权限，
不应提交到 Git、发送到公共聊天或复制给不需要管理员权限的用户。

需要通过负载均衡器或外部域名访问 API Server 时，可以设置 `kubeconfig_server`。该变量只修改导出的副本，
不会修改控制平面节点上的 `/etc/kubernetes/admin.conf`。

## 重置集群

重置会删除 Inventory 中 `k8s_cluster` 组所选主机上的 Kubernetes 状态。运行前应确认 Inventory、目标主机和
`cluster_name` 均正确。

```bash
ansible-playbook -i inventories/my-cluster/hosts.yml playbooks/reset.yml \
  -e kubernetes_reset_confirm=true \
  -e kubernetes_reset_cluster_name=<cluster_name>
```

Playbook 会执行：

- `kubeadm reset --force`；
- 删除 `/etc/cni/net.d`、`/var/lib/cni` 和 kubelet PKI；
- 删除 `/etc/kubernetes` 和 root kubeconfig；
- 重启所选容器运行时；
- 删除 Ansible 控制端导出的管理员 kubeconfig。

`kubeadm reset` 不会清理 iptables、nftables 或 IPVS 规则。需要把节点恢复为完全未使用状态时，还应根据主机
实际使用的网络栈单独检查和清理这些规则。
