# 离线包占位目录

请勿在此提交生成的软件包、二进制文件、容器镜像、凭据或 kubeconfig 文件。

仓库中的 `packages/`、`images/`、`manifests/` 和 `bin/` 只通过 `.gitkeep` 保留目录结构；`.gitignore` 会忽略
放入其中的真实内容。准备离线安装时，可以把资源放到本目录，也可以在仓库外维护离线包并通过
`offline_bundle_path` 指向它。

推荐在联网机器上使用 `./ops.sh offline-build --distro <系统> --release <版本> --arch <架构>` 自动生成完整
离线包。生成结果默认位于 `dist/offline/`，不会写入本占位目录或提交到 Git。

支持的离线包结构请参阅 `docs/offline-installation.md`。
