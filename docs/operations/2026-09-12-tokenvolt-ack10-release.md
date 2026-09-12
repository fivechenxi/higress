# TokenVolt ack.10 发布与中断计量修复

2026-09-12，TokenVolt 负责人明确说明已与 Higress maintainer 确认可直接合并，授权合并、发布并用其他模型执行 100 次复测。Codex 参与实现与验证；此记录不声称取得了独立可验证的上游 issue-spec 审批。

## 版本与验证

- Higress PR #2 已合并，main `bb4ba8aa33232b5cbc3ce5a9a5f93b33401b9466`，修复提交 `defb9b6`。
- ai-statistics `2.0.3-tokenvolt.1-alpha`，Actions `34684378149` 成功。Go/Wasm 全套 `go test -count=1 ./...` 通过；请求模型回填、SSE 分帧 ID、独立部分 usage、完成标记与重复收尾均有回归测试。
- 控制面 PR #30 已合并，`v0.2.0-ack.10` / `26f2d3967eb88cb90a63d78c78d9d22f259681b0`，Actions `34684375190` verify/publish 成功。`go test ./...`、`go vet ./...` 与发布 `make verify` 通过。
- 控制面镜像 `ghcr.io/tokenvolt-ai/tokenvolt-control-plane@sha256:0f993657cf19dcb91274cb4038200ea1cd52cc4a1df71648f804a535fc807a99`，Chart 0.1.21。
- OCI release index `1891c899a2bb4ece3103f2e5dd3f3e69c5840c4257f5087b694d130b5644c028`，linux/amd64 manifest `02548620e3f74e92dbb61bf848f840000b1524588aef39ee8a77c525b70d9a3b`。

## 插件分发

两个网关从 GHCR 获取新插件均在 30 秒超时，直接访问 GitHub release 也在 25 秒内未开始下载。部署验收发现仍为旧插件后暂停模型测试，未把失败的下载当作发布成功。

建立 Terraform 管理的专用公开制品桶 `tokenvolt-plugins-1150088752341921-cn-beijing`，仅用于原本已公开发布的二进制，不存放业务数据。该桶启用公开读取；公开访问设置只作用于此桶。发布文件由 GitHub Release 下载并与 `SHA256SUMS` 校验后上传：

`https://tokenvolt-plugins-1150088752341921-cn-beijing.oss-cn-beijing.aliyuncs.com/ai-statistics/sha256/54ad15680a864eb0f02e23ec5196cb14759862002f4cab9c54b690638e1d1d93.wasm`

Wasm 文件 SHA-256 为 `54ad15680a864eb0f02e23ec5196cb14759862002f4cab9c54b690638e1d1d93`。HTTPS 模式校验文件哈希，而非 OCI manifest。部署 precondition 要求 HTTPS 路径包含与配置校验和相同的哈希。每次发布须先核验、上传新哈希路径，再更新引用；不可覆盖旧哈希对象。网关实测下载 6,327,780 字节用时 0.109 秒。

## 部署与回滚

先更新 SLS 新元数据索引，再预拉取控制面镜像、部署应用和插件。增加的基础设施只有专用制品桶、桶 ACL 和桶公开访问配置，其余计划均为 Helm 原地更新；无数据库迁移。`helm lint`、`tofu validate` 通过；最终 plan 退出码 0，无变更。受限备份位于 `~/.local/share/tokenvolt/release-ack10-20260912`，禁止提交 state、tfvars、凭据或 kubeconfig。

控制面 Ready，readyz 返回 ready；网关配置均确认新 Wasm 文件摘要。原两个网关未重启，加载期间 HPA 扩到四个，新增网关同样确认新插件。

回滚应用时恢复备份中的 ack.9 镜像、插件 URL/校验和及 Chart，审阅仅 Helm 更新的 plan 后 apply。SLS 新索引可保留；制品桶不在常规回滚中删除。不要使用完整旧 state 覆盖现有 state。

## 100 次验收

使用 DeepSeek-V4-Pro：40 次普通响应、40 次完整流式、20 次主动中断（10 次首个内容/推理分片后，10 次第 20 个分片后）。包含长短输入、长短输出目标、复用和唯一前缀。无自动重试。测试企业仅临时增加此模型授权，测试结束后恢复原模型集。

精确 usage 只来自上游实际报告。保留请求模型与 ID 不意味着能从正文恢复精确 Token；无 usage 的中断继续标为未知，单独与千帆官方 API 汇总差额对账。最终结果见控制面 `docs/operations/2026-09-12-ack10-pro-100-reconciliation.md`。
