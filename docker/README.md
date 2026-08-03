# 使用 Docker 运行 Ansible

本目录把 Ansible 控制端依赖封装进容器。本机只需要 Docker 和 Compose 插件；目标 Kubernetes 节点仍由
现有 Playbook 通过 SSH 管理。

在仓库根目录执行统一入口最简单：

```bash
./ops.sh deploy \
  -i ansible/inventories/my-cluster/hosts.yml \
  --executor docker \
  --mode online
```

`ops.sh` 是推荐入口。`run.sh` 是 Docker 功能内部的底层入口，适用于需要完全控制 Ansible 原生参数的场景。

## 文件说明

```text
docker/
├── Dockerfile                    # Ansible 控制端镜像
├── Dockerfile.dockerignore       # 最小化构建上下文
├── compose.yml                   # 项目挂载和容器安全设置
├── entrypoint.sh                 # 准备临时 SSH 凭据
├── run.sh                        # ops.sh 调用的 Docker 底层入口
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

`run.sh` 会把容器工作目录设为 `/workspace/ansible`，所以下面的 Inventory 和 Playbook 路径相对于
仓库的 `ansible/` 目录。

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
cp -R ansible/inventories/example ansible/inventories/my-cluster
$EDITOR ansible/inventories/my-cluster/hosts.yml
$EDITOR ansible/inventories/my-cluster/group_vars/all.yml
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

项目根目录挂载为容器内的 `/workspace`，容器工作目录是 `/workspace/ansible`，因此导出的 kubeconfig 会直接保留
在宿主机 `ansible/artifacts/`。

## 离线安装路径

完整离线包中包含当前控制机架构的 Ansible 镜像。在断网机器上可以显式载入：

```bash
./ops.sh offline-load --bundle offline/bundles/<离线包目录>
```

使用 `ops.sh deploy --executor docker --mode offline --bundle ...` 时会自动载入。此时 `run.sh` 不运行 Docker
构建，并向 Compose 传入 `--pull never`；缺少本地镜像会直接失败，不会访问镜像仓库。

Playbook 中的文件路径按容器内路径解释。仓库根目录映射为 `/workspace`，因此仓库内离线包对应：

```yaml
install_mode: offline
offline_bundle_path: /workspace/offline/bundles/<离线包目录>
```

仓库外的离线包不会自动挂载。推荐将离线介质内容复制到项目忽略的 `offline/bundles/`，再通过根目录的
`ops.sh` 调用；完整流程参阅[离线安装说明](../offline/README.md)。

## 直接使用 Compose

不需要 SSH 的检查命令也可以直接运行：

```bash
docker compose -f docker/compose.yml run --build --rm ansible ansible --version
```

实际部署推荐使用 `run.sh`，它会处理交互式终端和可选 SSH 挂载，并使用镜像内已有的非 root 用户运行 Ansible。

## 注意事项

- 容器不使用 `privileged`，不挂载 Docker Socket，也不会在容器中运行 Docker Daemon。
- 私钥复制到容器临时文件系统后会设置为 `0600`，容器退出后自动销毁。
- `docker/.env`、真实 Inventory、离线包内容和 `ansible/artifacts/` 都不会进入镜像。
- 如果 Docker 宿主机本身是部署目标，Inventory 中的 `localhost` 指向容器自身，应改用宿主机可访问地址。
- 修改 `ansible/requirements.txt`、`ansible/requirements-dev.txt`、`ansible/requirements.yml` 或 Dockerfile 后，
  下次运行会自动重新构建受影响的镜像层。
