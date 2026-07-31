# 离线安装

离线模式使用与传输方式无关的离线包。Ansible 可以从控制端复制该目录，也可以让所有节点从 dufs、Nginx、
MinIO 或对象存储网关等 HTTP 服务下载同一个 tar 归档。

## 使用 ops.sh 制作离线包

制作机器需要能够访问软件源、GitHub 和镜像仓库，并安装可用的 Docker。目标节点不需要访问公网。

下面的命令会启动一次性 Ubuntu 24.04 构建容器，为 amd64 节点下载精确版本的 Kubernetes deb、containerd
及依赖、crictl、Flannel 清单和全部相关镜像：

```bash
./ops.sh offline-build \
  --distro ubuntu \
  --release 24.04 \
  --arch amd64 \
  --kubernetes-version 1.36.3
```

第一次正式下载前可以只检查解析结果：

```bash
./ops.sh offline-build \
  --distro ubuntu \
  --release 24.04 \
  --arch amd64 \
  --plan
```

默认输出位于 `dist/offline/`，包括离线目录、HTTP 分发使用的 tar.gz 和归档 SHA-256。构建过程先写入系统临时
目录，全部资源和内部 `SHA256SUMS` 验证通过后才移动到最终目录；如果输出已经存在，脚本会停止而不是覆盖。

当前自动制作功能支持：

- Ubuntu 或 Debian 目标系统；
- amd64 或 arm64；
- containerd；
- Flannel，或能够提供固定 YAML URL 和 SHA-256 的其他 CNI；
- 通过多个 `--extra-image` 添加业务或附加组件镜像。

使用其他静态 CNI 清单时，必须固定清单 URL 和摘要，例如：

```bash
./ops.sh offline-build \
  --distro ubuntu \
  --release 24.04 \
  --arch amd64 \
  --cni calico \
  --cni-manifest-url https://example.internal/calico.yaml \
  --cni-manifest-checksum sha256:<64位摘要> \
  --cni-manifest-name calico.yaml
```

脚本会从静态 YAML 的 `image:` 字段收集 CNI 镜像。使用 Helm、多文件或运行时动态选择镜像的 CNI 时，应通过
`--extra-image` 补齐镜像，或先生成一份最终静态清单。第一版制作工具不支持 CRI-O。

## 离线包结构

```text
k8s-offline-bundle/
├── bin/
│   └── crictl
├── packages/
│   ├── containerd_*.deb
│   ├── kubeadm_*.deb
│   ├── kubectl_*.deb
│   ├── kubelet_*.deb
│   └── 所有必需的 Debian 软件包依赖
├── images/
│   ├── kubernetes-images.tar
│   └── cni-images.tar
└── manifests/
    └── kube-flannel.yml
```

各目录由不同阶段使用：

| 目录 | 使用者 | 作用 |
| --- | --- | --- |
| `bin/` | `crictl`、`artifact_server_dufs` Role | 存放不通过 apt 安装的静态二进制。 |
| `packages/` | `os_prepare` Role | 存放 Kubernetes、容器运行时及其全部 Debian 依赖。 |
| `images/` | `container_runtime` Role | 存放要预载到 containerd 或 CRI-O 的镜像归档。 |
| `manifests/` | `cni`、`addons` Role | 存放 CNI 和可选附加组件的 Kubernetes YAML 清单。 |

`artifact_bundle` Role 会先把本地目录或 HTTP 归档统一放到目标主机的 `offline_remote_dir`，再检查上述内容。
检查通过后，后续 Role 只读取这个统一目录，不再访问 Ansible 控制端或公网。

软件包依赖必须与目标系统发行版和架构匹配。操作系统版本或 CPU 架构不同时，应分别制作离线包。安装程序会在
安装软件包前确认离线包中包含 kubeadm、kubelet、kubectl、所选容器运行时、CNI 清单和至少一个镜像归档。

离线模式不会自动解析或下载缺失的 deb 依赖。如果 `apt-get --no-download` 报告依赖缺失，应在有网络且与目标
节点同发行版、同架构的构建机上补齐软件包，然后重新制作离线包；不要在目标节点临时开启公网软件源绕过检查。

启用 `install_crictl` 时，请将目标架构对应的 Linux 二进制文件解压到 `bin/crictl`。Role 会将它复制到
`/usr/local/bin/crictl`、设置可执行权限、生成 `/etc/crictl.yaml`，并在 kubeadm 运行前验证配置的 CRI 端点。

镜像归档必须能够被所选运行时读取。使用 containerd 时，可以通过 `ctr`、`nerdctl` 或其他兼容 OCI 的工具
创建归档。安装程序会将所有 `images/*.tar` 文件导入 `k8s.io` 命名空间。

## 从控制端复制

适合节点数量较少、控制端能够直接通过 SSH 传输全部文件的环境。每台节点都会从控制端接收一份完整目录：

```yaml
install_mode: offline
offline_bundle_path: /srv/k8s-offline-bundle
offline_bundle_url: ""
```

使用统一入口部署时不必修改这三个变量，`ops.sh` 会以额外变量传给 Playbook：

```bash
./ops.sh deploy \
  -i inventories/my-cluster/hosts.yml \
  --executor docker \
  --mode offline \
  --bundle dist/offline/k8s-1.36.3-ubuntu-24.04-amd64
```

Docker 执行环境只能访问仓库目录内的文件，因此离线包应保存在 `dist/`、`files/` 或其他仓库子目录中。

## 通过 HTTP 下载

适合节点较多或离线包较大的环境。将目录制作成 tar 归档并发布到所有节点可访问的 HTTP 服务器：

```yaml
install_mode: offline
offline_bundle_path: ""
offline_bundle_url: http://192.0.2.10:666/k8s-offline-bundle.tar.gz
offline_bundle_checksum: sha256:<归档校验和>
```

归档校验和必须通过另一条可信渠道发布。软件包安装使用 `--no-download`，缺少依赖时会直接失败，不会静默访问
主机已配置的 apt 软件源。

可选的 `playbooks/artifact-server.yml` 会在第一台控制平面主机上安装 dufs。它只是辅助工具，并非 Kubernetes
各 Role 的依赖。
