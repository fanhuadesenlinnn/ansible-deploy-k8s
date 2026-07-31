# Security policy

Do not commit SSH private keys, kubeconfig files, bootstrap tokens, registry passwords, or production inventory data.

Use Ansible Vault, an external secret manager, or CI-provided secrets for sensitive variables. Generated kubeconfig files are
written under `artifacts/`, which is ignored by Git.

Non-example inventory directories are ignored by Git. Keep checksums configured for downloaded manifests, binaries, and
offline bundle archives; update the corresponding checksum whenever a custom URL or version is selected.

The destructive reset playbook requires both `kubernetes_reset_confirm=true` and the exact value of `cluster_name`. It
removes the role-managed root and exported kubeconfig files, but kubeadm does not clean iptables, nftables, or IPVS rules.

Report a vulnerability privately through GitHub Security Advisories rather than opening a public issue.
