# 安全策略

请勿提交 SSH 私钥、kubeconfig 文件、引导令牌、镜像仓库密码或生产环境 Inventory 数据。

敏感变量应使用 Ansible Vault、外部密钥管理器或 CI 提供的 Secret。生成的 kubeconfig 文件会写入
`artifacts/`，该目录已被 Git 忽略。

除示例以外的 Inventory 目录均会被 Git 忽略。下载清单、二进制文件和离线归档时必须配置校验和；使用
自定义 URL 或版本时，请同步更新对应的校验和。

破坏性的重置 Playbook 要求同时提供 `kubernetes_reset_confirm=true` 和与 `cluster_name` 完全一致的值。
它会删除本项目管理的 root kubeconfig 和导出到控制端的 kubeconfig，但 kubeadm 不会清理 iptables、
nftables 或 IPVS 规则。

发现安全漏洞时，请通过 GitHub Security Advisories 私下报告，不要创建公开 Issue。
