# 离线安装

离线模式使用与传输方式无关的离线包。Ansible 可以从控制端复制该目录，也可以让所有节点从 dufs、Nginx、
MinIO 或对象存储网关等 HTTP 服务下载同一个 tar 归档。

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
