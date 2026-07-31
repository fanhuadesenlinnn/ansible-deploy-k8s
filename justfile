set dotenv-load

inventory := env_var_or_default("INVENTORY", "inventories/example/hosts.yml")

install:
    python3 -m pip install -r requirements.txt
    ansible-galaxy collection install -r requirements.yml

install-dev:
    python3 -m pip install -r requirements-dev.txt
    ansible-galaxy collection install -r requirements.yml

check:
    yamllint .
    ansible-lint
    bash scripts/check-no-private-data.sh
    ansible-playbook -i {{inventory}} playbooks/site.yml --syntax-check
    ansible-playbook -i {{inventory}} playbooks/addons.yml --syntax-check
    ansible-playbook -i {{inventory}} playbooks/reset.yml --syntax-check
    ansible-playbook -i {{inventory}} playbooks/artifact-server.yml --syntax-check

ping:
    ansible -i {{inventory}} k8s_cluster -m ansible.builtin.ping

deploy *args:
    ansible-playbook -i {{inventory}} playbooks/site.yml {{args}}

addons *args:
    ansible-playbook -i {{inventory}} playbooks/addons.yml {{args}}

reset *args:
    ansible-playbook -i {{inventory}} playbooks/reset.yml {{args}}
