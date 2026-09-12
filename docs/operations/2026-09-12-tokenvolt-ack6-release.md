# TokenVolt v0.2.0-ack.6 发布记录

2026-09-12，经用户批准，将 ACK 控制面与 Portal 从 `v0.2.0-ack.5` 升级至 `v0.2.0-ack.6`。

## 版本与变更范围

- 控制面源提交：`df8690db98903880628030739dec318364dee0ee`，PR https://github.com/TokenVolt-ai/tokenvolt-control-plane/pull/25 已合并。
- Release：https://github.com/TokenVolt-ai/tokenvolt-control-plane/releases/tag/v0.2.0-ack.6
- 控制面镜像：`ghcr.io/tokenvolt-ai/tokenvolt-control-plane@sha256:aa9b70c7fe9f742bdaed42813653a83b876e4df110dd107c54f6a6b34a362c3b`
- Chart：`0.1.16`，appVersion `0.2.0-ack.6`。
- Terraform 计划和应用均为 **0 新增、1 原位更新、0 删除**；唯一更新资源为 `helm_release.tokenvolt[0]`，Helm values 只有控制面镜像变化。
- 无数据库迁移；策略插件保留已验证的 `9e2deb470acb1c110910b3e6ec34b9f7760d6d80db4945c4b33da2384d8a18b7` manifest。fixture、ACK、CLB、RDS、SLS、DNS 不变。

## 验证

- GitHub Actions verify、publish 成功；本地 make verify 通过，前端 65 项测试通过。
- 新 Pod `tokenvolt-control-plane-84965d55d8-2gtfc` 1/1 Ready、0 重启，镜像拉取约 7 秒；旧实例在新实例就绪后退出。
- 应用 `/healthz` 返回 ok、`/readyz` 返回 ready。
- 线上前端资产为 `index-QBdeDrHe.js`、`index-B8eXUz4I.css`，与发布构建一致。
- Chrome 新标签确认管理员会话、API 地址输入框、公开模型关联/新建/修改/解除入口。修改表单取消后，原样保存现有 3 渠道配置成功，不再出现 invalid_json。
- 升级后通过原页面草稿中的现有 Key 复测千帆 `/v2/models`，仍返回 40 个模型；测试后取消并恢复原页面，未提交千帆草稿。
- 发布后日志未出现配置同步失败或 panic。

## 回滚

本机受限备份保留升级前 Terraform state/vars、Helm values 和部署快照，位于 `~/.local/share/tokenvolt/release-ack6-20260912`。这些文件可能含敏感配置，不提交仓库。

如需回滚，将 `tokenvolt_control_plane_image` 恢复为 `ghcr.io/tokenvolt-ai/tokenvolt-control-plane@sha256:805ae796aabac0107dcb18d4aab25972adbb3ab4fafc47a8e86b60e19d6abdee`，同时同步受限 tfvars，重新审阅 Terraform plan 后 apply。Helm 开启 atomic、wait；滚动更新 maxUnavailable=0、maxSurge=1。
