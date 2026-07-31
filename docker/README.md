# 使用 Docker 运行 Ansible

本目录把 Ansible 控制端依赖封装进容器。本机只需要 Docker 和 Compose 插件；目标 Kubernetes 节点仍由
现有 Playbook 通过 SSH 管理。

推荐入口 `run.sh` 适用于带 Bash 的 macOS、Linux 或 WSL。其他环境仍可直接使用文末的 Compose 命令。

## 文件说明

```text
docker/
├── Dockerfile                    # Ansible 控制端镜像
├── Dockerfile.dockerignore       # 最小化构建上下文
├── compose.yml                   # 项目挂载和容器安全设置
├── entrypoint.sh                 # 准备临时 SSH 凭据
├── run.sh                        # 推荐的运行入口
├── .env.example                  # 宿主机 SSH 路径示例
└── README.md                     # 本文档
```

## 准备 SSH

推荐只挂载部署所需的单个私钥和 `known_hosts`，不要把整个 `~/.ssh` 目录放入容器：

```bash
cp docker/.env.example docker/.env
$EDITOR docker/.env
```

填写宿主机绝对路径：

```dotenv
ANSIBLE_SSH_PRIVATE_KEY=/Users/your-name/.ssh/id_ed25519
ANSIBLE_KNOWN_HOSTS=/Users/your-name/.ssh/known_hosts
```

`known_hosts` 中应提前包含目标节点，并在加入前核对主机指纹。项目保持 SSH Host Key 校验开启，不会自动接受
未知主机。

也可以不填写私钥，让 `run.sh` 尝试转发当前 `SSH_AUTH_SOCK`；使用 SSH 密码时可以向 Playbook 传入
`--ask-pass`。不同 Docker 实现对宿主机 Unix Socket 的转发能力不同，私钥只读挂载方式更通用。

## 构建和检查

首次运行会自动构建镜像，后续运行复用 Docker 构建缓存：

```bash
./docker/run.sh ansible --version
./docker/run.sh ansible-galaxy collection list
```

运行项目语法检查：

```bash
./docker/run.sh \
  ansible-playbook \
  -i inventories/example/hosts.yml \
  playbooks/site.yml \
  --syntax-check
```

## 部署集群

真实 Inventory 仍放在项目原有位置，并由 Git 忽略：

```bash
cp -R inventories/example inventories/my-cluster
$EDITOR inventories/my-cluster/hosts.yml
$EDITOR inventories/my-cluster/group_vars/all.yml
```

验证 SSH：

```bash
./docker/run.sh \
  ansible \
  -i inventories/my-cluster/hosts.yml \
  k8s_cluster \
  -m ansible.builtin.ping
```

部署：

```bash
./docker/run.sh \
  ansible-playbook \
  -i inventories/my-cluster/hosts.yml \
  playbooks/site.yml
```

项目根目录挂载为容器内的 `/workspace`，因此导出的 kubeconfig 会直接保留在宿主机 `artifacts/`。

## 离线安装路径

Playbook 中的文件路径按容器内路径解释。仓库根目录映射为 `/workspace`，因此仓库内离线包应配置为：

```yaml
install_mode: offline
offline_bundle_path: /workspace/files/offline-bundle
```

仓库外的离线包不会自动挂载。可以把它放入项目忽略的 `files/offline-bundle/`，或者在 `compose.yml` 中增加
一条只读挂载并使用对应的容器路径。

## 直接使用 Compose

不需要 SSH 的检查命令也可以直接运行：

```bash
docker compose -f docker/compose.yml run --build --rm ansible ansible --version
```

实际部署推荐使用 `run.sh`，它会处理用户 UID/GID、交互式终端和可选 SSH 挂载。

## 注意事项

- 容器不使用 `privileged`，不挂载 Docker Socket，也不会在容器中运行 Docker Daemon。
- 私钥复制到容器临时文件系统后会设置为 `0600`，容器退出后自动销毁。
- `docker/.env`、真实 Inventory、离线包内容和 `artifacts/` 都不会进入镜像。
- 如果 Docker 宿主机本身是部署目标，Inventory 中的 `localhost` 指向容器自身，应改用宿主机可访问地址。
- 修改 `requirements.txt`、`requirements.yml` 或 Dockerfile 后，下次运行会自动重新构建受影响的镜像层。
