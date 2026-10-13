# 旧部署停用与应急启用

2026-10-13，ACK 的日常发布已交接到 [TokenVolt-ai/tokenvolt-deploy](https://github.com/TokenVolt-ai/tokenvolt-deploy/blob/main/docs/operations/release-and-deploy.md)。本仓库保留作参考与应急材料，不再用于日常部署。

## 已停用什么

- GitHub 上三个旧插件发布 Action 已手动禁用：`tokenvolt-ai-statistics-release.yml`、`tokenvolt-ai-token-ratelimit-release.yml`、`tokenvolt-cluster-key-rate-limit-release.yml`。文件、历史 run、tag 和制品均保留，未删除 Secret。
- 本目录标准 Make 入口的 init/plan/start/stop/destroy、backend-bootstrap/backend-migrate、config-push、制品同步/发布默认退出；直接调用对应脚本同样受保护。
- `tofu.sh` 的所有调用（包括 `-chdir`、state 命令）、节点迁移脚本、直接执行 ACR 凭据包装器也默认退出，发生在读取凭据或调用云端之前。`remote-config.sh push/prepare` 默认退出；`config-pull/config-status/config-history` 保留供只读查阅（pull 仅更新本地副本）。
- 没有修改 ACK、Pod、Helm release、OSS 内容、云权限或共享凭据；新仓库的流程不受影响。

这是标准入口的防误操作保护，不是撤销 IAM 权限。**必须更新到含此保护的主干；历史 tag/旧 clone、裸 `tofu/helm/aliyun` 命令仍可能绕过。** 不要继续从历史部署 checkout 操作生产，也不要用 Make 变量覆盖标准入口来绕过保护。

## 快速应急启用（须先明确批准）

新流程出现问题时，优先在新独立 release 内回退版本，**不是重新跑旧整包 start/stop/destroy**。旧整包和新 release 管理权不兼容，不能因为打开开关就直接恢复旧部署。

确需旧工具时，先暂停新部署及 OSS 写入，核对当前 state、资源管理权、备份及操作范围；在更新过的旧 checkout，仅给审核过的单条命令加环境变量。例如先执行只读 plan：

```bash
TOKENVOLT_LEGACY_DEPLOYMENT=approved-emergency make -C deploy/ack plan
```

命令结束即恢复默认关闭；不要全局 export、写入 shell profile 或给 CI 常驻设置。原有 OSS 基线、凭据和其他检查仍然保留，开关不会绕过它们。旧 OSS 指向历史 tag 时检查可能拒绝当前 HEAD；不得为绕过检查直接恢复旧 state、覆盖旧 OSS 或切回无保护历史 tag，需要单独审核恢复方案。

只有确需旧制品发布时，逐个恢复必要的 workflow（不会自动运行）：

```bash
gh workflow enable tokenvolt-ai-statistics-release.yml -R fivechenxi/higress
# 如需要，再对 ai-token-ratelimit / cluster-key-rate-limit 的 workflow 执行 enable。
```

用完再次关闭同一个 workflow：

```bash
gh workflow disable tokenvolt-ai-statistics-release.yml -R fivechenxi/higress
```

检查停用状态：

```bash
gh api repos/fivechenxi/higress/actions/workflows \
  --jq '.workflows[] | select(.name | startswith("TokenVolt")) | {name,state}'
```

预期三个发布流程均为 `disabled_manually`。此操作不归档仓库、不删除任何备份，也不回退已经完成的新 Helm 管理权交接。
