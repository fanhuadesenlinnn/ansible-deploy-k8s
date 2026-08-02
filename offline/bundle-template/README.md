# 离线包目录模板

请勿在此提交生成的软件包、二进制文件、容器镜像、凭据或 kubeconfig 文件。

仓库中的 `packages/`、`images/`、`manifests/`、`bin/` 和 `controller/` 只通过 `.gitkeep` 保留目录结构；`.gitignore` 会忽略
放入其中的真实内容。本目录仅用于说明离线包结构；正式构建结果统一写入 `offline/bundles/`。

推荐在联网机器上使用 `./ops.sh offline-build --distro <系统> --release <版本> --arch <架构>` 自动生成完整
离线包。生成结果默认位于 `offline/bundles/`，不会写入本模板目录或提交到 Git。

支持的离线包结构请参阅 `offline/README.md`。
