# justfile 为常用命令提供短入口；安装 just 后，可通过 `just <任务名>` 执行。
set dotenv-load

# 可通过环境变量覆盖，例如：INVENTORY=inventories/prod/hosts.yml just deploy。
inventory := env_var_or_default("INVENTORY", "inventories/example/hosts.yml")

# 安装运行项目所需的 Python 依赖和 Ansible Collection。
install:
    python3 -m pip install -r requirements.txt
    ansible-galaxy collection install -r requirements.yml

# 在运行依赖基础上安装 ansible-lint、yamllint 等开发检查工具。
install-dev:
    python3 -m pip install -r requirements-dev.txt
    ansible-galaxy collection install -r requirements.yml

# 执行与 CI 相同的静态检查和全部 Playbook 语法检查。
check:
    yamllint .
    ansible-lint
    bash scripts/check-no-private-data.sh
    ansible-playbook -i {{inventory}} playbooks/site.yml --syntax-check
    ansible-playbook -i {{inventory}} playbooks/addons.yml --syntax-check
    ansible-playbook -i {{inventory}} playbooks/reset.yml --syntax-check
    ansible-playbook -i {{inventory}} playbooks/artifact-server.yml --syntax-check

# 验证 Ansible 能否通过 SSH 和 Python 连接所有 Kubernetes 主机。
ping:
    ansible -i {{inventory}} k8s_cluster -m ansible.builtin.ping

# 安装或扩容集群；额外参数会原样传给 ansible-playbook，例如 `just deploy --check`。
deploy *args:
    ansible-playbook -i {{inventory}} playbooks/site.yml {{args}}

# 独立安装或更新 group_vars 中启用的可选附加组件。
addons *args:
    ansible-playbook -i {{inventory}} playbooks/addons.yml {{args}}

# 破坏性重置入口；仍需显式传入 reset.yml 要求的两个确认变量。
reset *args:
    ansible-playbook -i {{inventory}} playbooks/reset.yml {{args}}
