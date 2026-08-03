# justfile 为常用命令提供短入口；安装 just 后，可通过 `just <任务名>` 执行。
set dotenv-load

# just 只提供短别名；实际部署、检查和确认逻辑仍统一进入 ops.sh。
inventory := env_var_or_default("INVENTORY", "ansible/inventories/example/hosts.yml")
executor := env_var_or_default("EXECUTOR", "local")

# 安装运行项目所需的 Python 依赖和 Ansible Collection。
install:
    python3 -m pip install -r ansible/requirements.txt
    ansible-galaxy collection install -r ansible/requirements.yml

# 在运行依赖基础上安装 ansible-lint、yamllint 等开发检查工具。
install-dev:
    python3 -m pip install -r ansible/requirements-dev.txt
    ansible-galaxy collection install -r ansible/requirements.yml

# 执行与 CI 相同的静态检查和全部 Playbook 语法检查。
check:
    yamllint .
    cd ansible && ansible-lint
    bash scripts/check-no-private-data.sh
    bash scripts/test-ops-menu.sh
    bash scripts/test-offline-build-independent.sh
    ./ops.sh check -i {{inventory}} --executor {{executor}}

# 验证交互菜单的导航、返回、退出和错误恢复；不会连接或修改目标节点。
test-menu:
    bash scripts/test-ops-menu.sh

# 验证制作离线包不读取或依赖任何集群 Inventory。
test-offline-independent:
    bash scripts/test-offline-build-independent.sh

# 验证 Ansible 能否通过 SSH 和 Python 连接所有 Kubernetes 主机。
ping:
    ./ops.sh ping -i {{inventory}} --executor {{executor}}

# 安装或扩容集群；额外参数会原样传给 ansible-playbook，例如 `just deploy --check`。
deploy *args:
    ./ops.sh deploy -i {{inventory}} --executor {{executor}} --mode online --yes -- {{args}}

# 独立安装或更新 group_vars 中启用的可选附加组件。
addons *args:
    ./ops.sh addons -i {{inventory}} --executor {{executor}} --mode online --yes -- {{args}}

# 破坏性重置入口；仍需显式传入 reset.yml 要求的两个确认变量。
reset *args:
    ./ops.sh reset -i {{inventory}} --executor {{executor}} {{args}}
