# Security policy

Do not commit SSH private keys, kubeconfig files, bootstrap tokens, registry passwords, or production inventory data.

Use Ansible Vault, an external secret manager, or CI-provided secrets for sensitive variables. Generated kubeconfig files are
written under `artifacts/`, which is ignored by Git.

The destructive reset playbook is disabled unless `kubernetes_reset_confirm=true` is explicitly supplied.

Report a vulnerability privately through GitHub Security Advisories rather than opening a public issue.
