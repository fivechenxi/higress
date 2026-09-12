# TokenVolt ack.9 发布记录

日期：2026-09-12。TokenVolt 负责人批准完整发布及 20 次客户端中断复测。

## 发布

- 控制面 PR #28：https://github.com/TokenVolt-ai/tokenvolt-control-plane/pull/28
- 版本 `v0.2.0-ack.9`，源码 `70fb12d520209c9f56290f2938163931e4f5b39d`。
- GitHub Actions `34682893687` verify/publish 成功。
- 控制面镜像 `ghcr.io/tokenvolt-ai/tokenvolt-control-plane@sha256:310a01295dd3ed6d0b8a3c71f60a9fc0f2bbf6355033b50e8664c82011095d83`；Chart `0.1.20`。
- 保留现有镜像拉取凭据。两个节点预拉取成功后执行部署；plan 只有 `helm_release.tokenvolt[0]` 原地更新，0 新增、0 删除。apply 成功，再次 plan 为退出码 0、无变更。
- 受限备份 `~/.local/share/tokenvolt/release-ack9-20260912`，含原 state、vars、Chart、Deployment 和 Pod 快照；不得提交 Git。

## 线上验证

控制面新 Pod Ready 1/1，healthz=ok、readyz=ready；两个 Higress Gateway 的 UID 保持不变，重启计数均为 0。重启前后原测试企业的模型 grants 完全相同，测试 Key 的模型列表继续包含 deepseek-v4-flash、glm-5.2、kimi-k3。

管理员会话保留。用量页企业、Key、模型可搜索，按 Key 别名搜索、选择后提交真实 Key ID；模型页有一个企业搜索框，账单页查询及创建表单各有一个。未创建账单或修改客户配置。

本版本保留独立已知 input/output 聚合，修复 Higress 启动覆盖旧固定目录，并增加搜索下拉框。未修改或更新 Higress ai-statistics 插件；缺少最终 usage 的中断请求精确 Token 仍然未知。

20 次中断请求于北京时间 16:26:52–16:27:46 执行，无重试，均收到 HTTP 200 后主动断开。SLS 收齐 20 条，无重复，均无最终 usage。最终千帆官方 API 汇总增量为 20 次、输入 50,676、输出 587、共 51,263 Token，cache 17,152 Token、4 次命中。TokenVolt 已收齐 20 次中断与 20 条未知用量，但未计入上述 Token，说明无最终 usage 的中断计量尚未闭环。详见控制面 docs/operations/2026-09-12-ack9-release-reconciliation.md。

## 回滚

如需回滚应用，将控制面镜像恢复为 ack.8 的 `sha256:0ed723b1f20f1cbf2b37b4565f5c11b68f8e509c0a8769a787c6d47d4a2d5904`，并恢复匹配 Chart 0.1.19，审阅 plan 后 apply。无新数据库迁移。注意 ack.8 启动仍有固定目录覆盖授权的已知缺陷，应优先前向修复。

Codex 参与此次实现、部署及验证，按 TokenVolt 负责人的明确发布指令推进。此为 TokenVolt 使用的 fork 部署变更，不声明已取得上游 Higress maintainer 的 issue-spec 批准或例外。部署变更同步现有 PR #2。
