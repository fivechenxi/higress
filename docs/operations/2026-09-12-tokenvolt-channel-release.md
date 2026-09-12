# TokenVolt 渠道与模型重构发布记录

2026-09-12，ACK `tokenvolt-system` 控制面升级为 `v0.2.0-ack.5`，TokenVolt Chart 为 `0.1.15`。共享 CLB 和原有 www/newapi ECS 转发保持不变，`api.tokenvolt.net` 没有切流。

## 固定版本

- 控制面：`ghcr.io/tokenvolt-ai/tokenvolt-control-plane@sha256:805ae796aabac0107dcb18d4aab25972adbb3ab4fafc47a8e86b60e19d6abdee`
- 策略使用发行镜像的 linux/amd64 manifest：`oci://ghcr.io/tokenvolt-ai/tokenvolt-policy@sha256:9e2deb470acb1c110910b3e6ec34b9f7760d6d80db4945c4b33da2384d8a18b7`
- `policyPluginSha256` 同为 `9e2deb470acb1c110910b3e6ec34b9f7760d6d80db4945c4b33da2384d8a18b7`。
- 发行 OCI index 为 `0268193e7ef2ec5424f767df0a02b060f42e63e9f501982170e5fab7f2908fd5`；已校验 index → platform manifest → layer → `plugin.wasm`，裸 Wasm SHA 为 `4fe9e3b5621f7ba80528bdfea5dddaace2afb8de552eff678d03bd1179852eb7`，与原生验收版本一致。

## 部署变更

- publisher Role 增加对其 EnvoyFilter 配置的 get/create/update/delete 权限，用于模型渠道的跨优先级切换。
- 新控制面从已有内部/公开模型域名环境变量推导域名级策略，不再只保护入口 Ingress。模型 `/v1` 由策略鉴权；Portal `/api/v1` 仍由控制面鉴权。
- RDS 迁移 0011 增加渠道上游模型列表、基础路径、模型表、路由优先级。升级前进行事务内迁移演练并回滚，再由应用启动正式迁移。
- 升级前后，3 个渠道及凭据、5 条原路由字段及权重、4 个 Key 校验值和状态、2 个用户密码摘要和状态的集合 SHA 完全相同。原路由 priority 为 0；迁移得到 3 个启用模型。
- 发布前完成 RDS 手工备份 `3156654884`（2026-09-12 03:53:54 UTC），并保存受限的 state、vars、Helm values 和配置快照。原始备份及凭据不进入 Git。

## 逐实例生效检查

首次发布时有一个 gateway 到 GHCR 的 Wasm layer 下载超过 30 秒，导致该实例继续保留旧配置。数据库发布状态 active 并不等于每个 Envoy 实例已生效。

持久配置改用已验证的 linux/amd64 manifest，随后在另一个实例鉴权检查通过且 PDB 允许的前提下，驱逐并替换异常实例。最终两个 gateway 均 Ready，实际 Envoy 配置均包含新插件；对两个实例分别测试 `ack.tokenvolt.net` 和 `api.tokenvolt.internal`，伪造选路头配无效 Key 均返回 401。没有手工复制 Wasm 到生产缓存，也没有使用临时 HTTP 夹具作为生产插件地址。

这次恢复不等于根治 GHCR 跨境下载的不稳定性。该 Higress Istio 版本把远程 Wasm 下载超时固定为 30 秒（[固定版本源码](https://github.com/higress-group/istio/blob/65133dd61c6c597fb301c53beaa777ca5c9e4ba2/pilot/pkg/model/extensions.go#L300-L328)）。后续可将发行 OCI 镜像同步到同地域镜像仓库，再在 Terraform 中持久更新引用；镜像格式和控制面接口仍可跨云。

## 验收与清理

合成上游在同一 ACK 数据面验证了 503、429、超时主备切换、流式首包边界、上游模型映射和同层权重。测试 namespace、测试 WasmPlugin、测试 EnvoyFilter、数据库检查工作负载和六个临时注册项已删除，非测试 McpBridge 注册项逐项核对未改变。

[控制面完整验收报告与重跑方法](https://github.com/TokenVolt-ai/tokenvolt-control-plane/blob/main/docs/operations/ack-channel-model-acceptance.md)。真实收费厂商全模型回归和管理员登录后的生产 UI 全流程不在本次合成测试结论内。
