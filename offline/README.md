# 完整离线安装

完整离线包让 Ansible 控制端和 Kubernetes 目标节点在部署阶段都不访问公网。制作动作在联网机器完成；生成包固定
目标系统、架构、Kubernetes、容器运行时、CNI 和附加组件，部署前会逐项核对。

制作过程不读取 Ansible Inventory，不需要节点 IP、SSH 凭据或已经配置好的目标机器。离线包的默认版本、固定下载
地址和 SHA-256 集中保存在 [`defaults.yml`](defaults.yml)；真实 Inventory 只在安装阶段使用。

离线包包含：

- Kubernetes、containerd 或 CRI-O，以及 CRI-O 模式所需的 Podman 和全部必需 deb 依赖；
- crictl 和 dufs 静态二进制；
- kubeadm、运行时、CNI、所选附加组件和显式追加的全部容器镜像；
- CNI 与所选附加组件的最终静态 YAML；
- Docker Ansible 控制端镜像；
- `metadata.yml` 和覆盖包内全部文件的 `SHA256SUMS`。

不会打包操作系统本身、SSH 服务、sudo、Python、systemd 和 Linux 内核。这些是 Ansible 连接及 Kubernetes 运行的
基础环境，目标主机必须预先具备。使用本机 Ansible 执行时，本机也必须已经安装项目依赖；希望控制端也不预装
依赖时，应使用包内 Docker 镜像。

## 1. 在联网机器制作

制作机器只需要 Docker、Compose 插件以及访问软件源、GitHub 和镜像仓库的网络。下面为 Ubuntu 24.04 amd64
节点制作 containerd 离线包：

```bash
./ops.sh offline-build \
  --distro ubuntu \
  --release 24.04 \
  --arch amd64 \
  --runtime containerd \
  --kubernetes-version 1.36.3
```

`--arch` 是目标节点架构；`--controller-arch` 是运行 Docker Ansible 控制端的机器架构。比如在 Apple Silicon
Mac 上为 amd64 Linux 节点制作时，默认组合就是目标 `amd64`、控制端 `arm64`。

制作 CRI-O 包：

```bash
./ops.sh offline-build \
  --distro debian \
  --release 12 \
  --arch amd64 \
  --runtime crio
```

CRI-O 包会同时带上 Podman；部署时通过 `podman load` 将 OCI 归档导入 CRI-O 使用的容器存储。

### CNI 和附加组件

默认打包 Flannel。Calico、Cilium 或内部定制 CNI 应提供最终渲染的单文件静态清单：

```bash
./ops.sh offline-build \
  --distro ubuntu --release 24.04 --arch amd64 \
  --cni cilium \
  --cni-manifest-file offline/input/cilium.yaml \
  --cni-manifest-name cilium.yaml
```

本地文件的 SHA-256 会自动计算；使用 `--cni-manifest-url` 时必须同时传入
`--cni-manifest-checksum sha256:<64位摘要>`。

启用附加组件时，制作包和实际 Inventory 必须一致：

```bash
./ops.sh offline-build \
  --distro ubuntu --release 24.04 --arch amd64 \
  --addon metrics_server \
  --addon cert_manager \
  --addon reloader
```

`--addon` 使用 `offline/defaults.yml` 中固定的 URL 和摘要。内部组件或 Istio 自定义清单可用
`--addon-spec '名称|URL|sha256:<摘要>'`。脚本会提取所有静态清单中的 `image:`；由 Helm 模板、Operator 或脚本
动态决定、无法从 YAML 直接发现的镜像，必须用可重复的 `--extra-image <完整镜像引用>` 补齐。

集群建成后再运行离线 `./ops.sh addons` 时，流程也会先导入新离线包中缺失的镜像，再应用附加组件清单。

可先用 `--plan` 检查参数；该模式不访问网络，也不创建构建结果：

```bash
./ops.sh offline-build --distro ubuntu --release 24.04 --arch amd64 --plan
```

实际制作前会显示完整计划并要求确认；在经过审核的自动化任务中，可以显式加入 `--yes` 跳过确认。

## 2. 输出与校验

默认结果位于 `offline/bundles/`：

```text
k8s-...-containerd/
├── bin/
│   ├── crictl
│   └── dufs
├── packages/                    # Kubernetes、运行时及完整 deb 依赖
├── images/                      # 带完整引用标签的 OCI 镜像归档
├── manifests/
│   ├── kube-flannel.yml         # 所选 CNI
│   └── addons/                  # 制作时选择的附加组件
├── controller/
│   └── ansible-controller-image.tar
├── metadata.yml
└── SHA256SUMS
k8s-...-containerd.tar.gz        # HTTP 分发归档
k8s-...-containerd.tar.gz.sha256
```

目录和 tar.gz 应一起复制到离线网络。收到介质后先校验目录：

```bash
./ops.sh offline-validate --bundle offline/bundles/<离线包目录>
```

校验会拒绝旧版或不完整包，并验证每一个文件都被 `SHA256SUMS` 覆盖且摘要正确。目标节点还会再次核对自己的
发行版、版本、架构以及 Inventory 中的软件选择。不同发行版或 CPU 架构需要分别制作；当前一次部署使用一个包，
所以同一 Inventory 中的目标节点应具有相同系统和架构。

## 3. 完全离线的 Docker 控制端

在断网控制机载入包内 Ansible 镜像：

```bash
./ops.sh offline-load --bundle offline/bundles/<离线包目录>
```

使用目录部署时，`deploy` 会自动执行这一步。Docker 离线模式使用 `--pull never`，并且不会执行镜像构建；缺少
控制端镜像时会直接报错。

## 4. 从控制端目录部署

适合节点较少的环境，Ansible 通过 SSH 向每个节点复制完整目录：

```bash
./ops.sh deploy \
  -i ansible/inventories/my-cluster/hosts.yml \
  --executor docker \
  --mode offline \
  --bundle offline/bundles/<离线包目录>
```

Docker 执行器只能访问仓库目录，因此目录模式的离线包应保存在仓库内。使用 `--executor local` 时则可指定控制机
上的其他绝对路径。

## 5. 通过 dufs/HTTP 分发

节点较多时，可先把包内 dufs 和 tar.gz 投放到第一台控制平面主机：

```bash
./ops.sh offline-serve \
  -i ansible/inventories/my-cluster/hosts.yml \
  --executor docker \
  --bundle offline/bundles/<离线包目录> \
  --yes
```

该动作不下载安装 dufs；它直接使用包内二进制，并将同目录的 `<离线包目录>.tar.gz` 放入只读共享目录。默认端口
为 `8080`，需要在隔离网络防火墙中仅向集群节点开放。随后部署：

```bash
./ops.sh deploy \
  -i ansible/inventories/my-cluster/hosts.yml \
  --executor docker \
  --mode offline \
  --bundle-url http://<制品主机IP>:8080/<离线包目录>.tar.gz \
  --checksum sha256:<归档摘要>
```

归档摘要记录在制作时生成的 `.tar.gz.sha256` 文件中。使用 URL 模式时，Docker 控制端无法从 URL 提取自己的
镜像，因此应先运行一次 `offline-load`。

## 失败策略

离线模式不会调用公共 apt 源，也不会缺什么就临时拉什么。软件包安装使用 `apt-get --no-download`；Docker 控制端
禁用构建和拉取；目标运行时只导入 `images/*.tar`。以下任一情况都会在部署早期失败：

- 文件摘要错误或有文件未列入校验清单；
- 目标系统、架构、软件版本或运行时与元数据不符；
- Inventory 启用了包内没有的附加组件；
- deb 依赖、CNI 清单、crictl、dufs、控制端镜像或容器镜像缺失；
- 镜像归档导入后找不到元数据声明的完整镜像引用。
