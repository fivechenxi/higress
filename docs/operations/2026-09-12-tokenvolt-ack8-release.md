# TokenVolt 分钟用量与配置发布工作流交付

日期：2026-09-12。用户批准将近期分钟用量与此前草稿发布、激活上下文、企业搜索改动一起发布。

## 代码与版本

- 控制面 PR #26：https://github.com/TokenVolt-ai/tokenvolt-control-plane/pull/26
- 线上验收发现的超时状态补丁 PR #27：https://github.com/TokenVolt-ai/tokenvolt-control-plane/pull/27
- 最终发布源：`c3c281f38d9de543c7a0aa5e19fe230207d0b061`，版本 `v0.2.0-ack.8`。
- ack.8 控制面镜像：`ghcr.io/tokenvolt-ai/tokenvolt-control-plane@sha256:0ed723b1f20f1cbf2b37b4565f5c11b68f8e509c0a8769a787c6d47d4a2d5904`；Chart `0.1.19`。
- GitHub Actions `34680924566` 的 verify/publish 均成功；最终 Terraform plan 仅更新 `helm_release.tokenvolt[0]`，0 新增、0 删除。应用成功后再次 plan 退出码为 0、No changes。

## 已完成的中间发布与验证

ack.7（Chart 0.1.17）完成迁移 0012/0013，应用健康、就绪检查通过。旧控制面 Pod 先完全退出，再启动新版；两个 Gateway 保持运行。

近期采集每分钟运行，页面每分钟刷新。北京移动测试的 100 次请求、244,685 已知 Token、20 条 Token 未知与发布前一致。原小时数据与分钟回填同时存在时没有重复计数；页面水位连续前进，已在 Chrome 观察到无需手工操作的自动刷新。

SLS 索引增加 response_flags 文本分析字段，其余索引、180 天保留期不变。此项通过 API 先应用，再同步到 Terraform；历史未索引的中断记录无法完整统计，后续如需追溯应重建指定历史范围索引。

真实 ServiceAccount 验收发现 ACK WebSocket exec 的 get 权限不足，握手返回 403。Chart 0.1.18 加入 pods/exec create 后，两 Gateway 均握手 101、固定 curl 命令返回 Success，原样发布任务 #1 成功确认 data_plane。RBAC 无法约束 exec 命令，本权限只授予受信发布器，程序使用固定命令且不输出原始配置或凭据。

同时发现确认截止时间取消了持锁连接上的 Ping，导致连接关闭、失败状态写入失败。ack.8 分离健康检查的 context，连接丢失后在重新取得环境锁的事务内记录失败，不覆盖其他执行器已完成的结果。前端移除与最终状态冲突的“正在确认”旧提示。

## 运维约束与回滚

- ControlPlane 启用 gatewayConfigPublisher 时使用 Recreate，保证首次跨旧版发布器升级不重叠；控制面短暂不可用不重启 Gateway。
- 不新购 ECS、ACK、RDS、SLS 等云资源；仅更新既有应用、RBAC 与 SLS 索引。
- 受限备份：`~/.local/share/tokenvolt/release-ack7-20260912`、`~/.local/share/tokenvolt/release-ack8-20260912`，含 state/vars/部署快照，不能提交仓库。
- RDS 已确认 2026-09-12 03:51–03:53 UTC 的快照成功。新增迁移均保留既有业务表和数据。
- 回滚需同步 Terraform 中的镜像与匹配 Chart 配置，重新检查 plan 后 apply；保留 0012/0013 数据，不删除草稿或发布历史。回到 ack.6 时使用旧的直接保存发布流程，必须先停新版发布器，不能混用。

## 验证边界

本轮在线验收包含管理员会话保留、企业模糊搜索、历史用量总数、分钟采集水位、自动刷新、原样配置发布及真实网关运行配置读取；没有新增客户或客户 Key，也没有更改客户模型授权及上游路由。激活上下文、交叉编辑冲突、超时终态、连接丢失与重试由自动化和隔离 PostgreSQL 测试覆盖，没有对生产数据库做断线故障注入。

## 最终线上验收

ack.8 / Chart 0.1.19 已部署到 https://ack.tokenvolt.net/。新控制面 Pod Ready 1/1、重启 0，healthz/readyz 分别返回 ok/ready，数据库迁移 1–13 均已应用。两个 Higress Gateway 保持原 Pod 且重启 0。

浏览器刷新后保留管理员会话。原样配置任务 #2 于北京时间 15:45:38 提交、15:45:58 成功，数据库状态 succeeded、确认级别 data_plane；页面不再残留“正在确认”的矛盾提示。搜索“北京”选择北京移动测试后，自动加载 100 次请求、244,685 已知 Token、20 条未知 Token。未手工点击查询，页面从 15:46:17 自动刷新到 15:47:04，采集截至时间从 15:45 前进到 15:46，总量不变。

本地 make verify、前端 76 个测试、隔离 PostgreSQL 的真实超时/连接丢失/并发保护/近期统计测试及相关 race 检查均通过，Helm lint 和 diff 检查通过。完整控制面记录：[分钟用量与发布验收](https://github.com/TokenVolt-ai/tokenvolt-control-plane/blob/main/docs/operations/2026-09-12-minute-usage-and-ack7-release.md)。

本次镜像拉取耗时 4 分 21 秒，控制面在 Recreate 窗口暂不可用；后续可先预拉取新镜像再切换以缩短窗口。未变更 Gateway、策略插件或模型 mock 的镜像。

Codex 参与了本次实现、部署及验证，依照 TokenVolt 负责人的明确发布指令推进；此变更属于 TokenVolt 使用的 fork，不声明上游 Higress maintainer 已批准 issue-spec 或例外。部署分支继续提交到现有 PR #2，未代替维护者合并。
