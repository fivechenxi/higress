<!--
  ~ Copyright 2026 Alibaba Group Holding Ltd.
  ~
  ~ Licensed under the Apache License, Version 2.0 (the "License");
  ~ you may not use this file except in compliance with the License.
  ~ You may obtain a copy of the License at
  ~
  ~     http://www.apache.org/licenses/LICENSE-2.0
  ~
  ~ Unless required by applicable law or agreed to in writing, software
  ~ distributed under the License is distributed on an "AS IS" BASIS,
  ~ WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  ~ See the License for the specific language governing permissions and
  ~ limitations under the License.
-->

# ACK 远端状态与配置同步

这套部署将 OpenTofu State 存入私有 OSS Bucket，并使用 TableStore 防止多人同时
修改 State。Bucket 默认开启 AES-256 服务端加密和版本控制。`terraform.tfvars`
也保存在同一个 Bucket 的独立对象中，不进入 Git。

后端 Bucket、TableStore 实例和锁表是永久基础资源，`make stop` 和
`make destroy` 都不会删除它们。

## 首次迁移（只执行一次）

确认本机已有 `tokenvolt` 阿里云 CLI Profile（AK、STS 或 OAuth 均可），并在
`deploy/ack` 目录运行：

```bash
make backend-migrate
```

该命令会：

1. 创建私有、加密、启用版本控制的 OSS Bucket；
2. 创建容量型 TableStore 实例和 `LockID` 锁表；
3. 备份当前本地 State，再将其迁移到 OSS；
4. 上传当前 `terraform.tfvars` 并记录同步基线。

## 日常部署

新电脑或新工作目录先运行：

```bash
make init
make config-pull
```

之后沿用原来的命令：

```bash
export TF_VAR_tokenvolt_ghcr_token='<具有 read:packages 权限的 GitHub token>'
make plan
make start
make stop
```

`tokenvolt_ghcr_token` 不属于 tfvars：它继续由操作者在当前 Shell 或 CI Secret 中
提供，避免长期 GitHub 凭据进入共享配置对象。未提供时，启用了 TokenVolt 私有
镜像的 Plan 会按原有安全校验失败。policy Wasm 的北京 OSS HTTPS 地址不需要
registry 凭据。

## TokenVolt 镜像切换到北京 ACR

发布工作流完成 GHCR 和北京 ACR 双推送后，先从该次 GitHub Release 的
`IMAGE_DIGESTS.txt` 核对 **ACR 仓库对应的 digest**。只在需要实际切换 ACK 时
修改远端配置；本仓库的默认 GHCR 镜像和旧版本不随凭据配置自动切换。

```bash
cd deploy/ack
make init
make config-pull
make config-status
```

将本地 `terraform.tfvars` 中的 `tokenvolt_acr_registry` 设为镜像引用中的完整
registry **主机名**（不含 `https://` 或仓库路径），并把
`tokenvolt_control_plane_image` 设为该 ACR 仓库的
`<registry>/<namespace>/<repository>@sha256:<digest>`。若启用了
`tokenvolt_mock_enabled` 且 fixture 也要从 ACR 拉取，同样更新
`tokenvolt_mock_image` 为其独立的 ACR digest。镜像主机名必须与
`tokenvolt_acr_registry` 完全一致；仓库路径和 digest 均须从发布产物核对，
不能将 GHCR digest 假定为 ACR digest。确认所选公网或 VPC registry 地址可从
ACK 节点访问。

ACR 用户名和密码仅通过 `TF_VAR_tokenvolt_acr_username`、
`TF_VAR_tokenvolt_acr_password` 注入 OpenTofu 进程，**不要写入 tfvars、Git、
命令历史或 PR**。现有 `TF_VAR_tokenvolt_ghcr_token` 仍需提供，以保留 GHCR
镜像与 OCI 插件的拉取能力。OpenTofu 会将两个 registry 的认证合并到现有的
`tokenvolt-ghcr` Kubernetes Secret，并同步到 `higress-system`；Secret 名称
是历史名称，不表示只支持 GHCR。OpenTofu 的远端 State 也会保存 Secret 数据，
应按敏感凭据管理 State 的访问权限和版本历史。

切换窗口中先确认 `make config-status` 没有本地与 OSS 的并发修改，必要时查看
`make config-history`；再执行 `make config-push`、`make plan`。获得单独部署
授权后才执行 `make start`。应用后检查目标 Pod 的 image、imageID、Ready
状态和近期事件，确认实际运行的是本次 ACR digest。回退时用此前已核对的
GHCR digest 恢复镜像引用，再按同样流程同步配置和部署。

`plan/start/stop` 执行前会比较本地、OSS 和上次同步版本：

- OSS 较新且本地未修改：自动拉取；
- 本地已修改且 OSS 未变化：先 `make config-push`，然后再部署；
- 两边都修改：停止执行，要求人工合并；
- `start/stop` 成功后：自动把本地 `terraform.tfvars` 同步到 OSS；
- Apply 失败：检查实际资源与 State，并恢复或修正已同步的配置后重试。

OpenTofu 会在每次资源变更后自动写入 OSS State，不需要手工上传 State。
仓库内的 `scripts/tofu.sh` 会把 CLI OAuth Profile 的短期 STS 凭据仅注入当前
OpenTofu 进程，以兼容 OSS Backend；凭据不会打印或写入文件。

## 配置管理

```bash
make config-status   # 查看本地、远端和同步基线的 SHA-256
make config-pull     # 安全拉取；不会覆盖未同步的本地修改
make config-push     # 安全上传；不会覆盖其他人的远端修改
make config-history  # 查看 OSS 历史版本
```

确实需要覆盖时可直接调用：

```bash
./scripts/remote-config.sh pull --force
./scripts/remote-config.sh push --force
```

强制覆盖前应先执行 `make config-history`。OSS 版本控制可以恢复旧对象，但它不能
替代变更确认。

## 权限与注意事项

部署身份至少需要目标 State Bucket 的读写权限、TableStore 锁表读写权限，以及
实际 ACK Terraform 所需的云资源权限。`backend.tf` 和 `remote-config.hcl` 只有
非敏感位置参数，可以提交。不要把 `.terraform/tfvars-sync.sha256`、`terraform.tfvars` 或任何 State 文件
提交到 Git。

本地 `terraform.tfvars` 权限会被脚本设置为 `0600`。如果不再需要本地副本，可在
确认 `make config-status` 显示 `synchronized` 后手工安全删除；下次运行
`make config-pull` 即可恢复。

## 统计查询配置

控制面统计页的数据源必须通过共享 tfvars 持久配置，不能只修改运行中 Deployment：

```hcl
tokenvolt_usage_dashboard = {
  environment = "ack-test"
  source      = "legacy_usage"
}
```

`legacy_usage` 查询已有 RDS 用量汇总，不启用新的账单处理流程。两个字段必须
同时设置；均为空时统计查询关闭，页面应提示不可用，不能将其解释成零用量。

OSS 中的 `deployment_baseline_tag` 必须对应本次部署代码的精确 Git Tag。
更新部署代码时先提交并推送新 Tag，再更新共享 tfvars 中的 Tag 和配置，执行
`make config-push`，审阅 Plan 后 Apply。不要从旧代码目录直接更新新版本资源。

额度发布器同样必须持久配置：线上已启用额度管理时，在共享 tfvars 中设置
`tokenvolt_quota_enabled = true`。模板显式设置 `HIGRESS_QUOTA_ENABLED`，
避免下次部署丢失。默认关闭；启用前须部署配套的 Helm quota 插件资源。
发布 Tag 必须推到 `fivechenxi/higress`，仅在个人 fork 有同名 Tag 不算完成。

托管 Redis 的出站集群由 TokenVolt Helm chart 与插件共用的 serviceName/port
派生。已有手工 EnvoyFilter 的环境须先按 [Redis 接管说明](REDIS_CLUSTER_ADOPTION.md)
审阅所有权迁移与回退方案；不要直接应用控制面仓库的旧静态 YAML。

## 归档 dirty Worker 切换检查

`tokenvolt_archive_dirty_worker.enabled`、`tokenvolt_archive_cutover_paused` 和
`tokenvolt_external_metrics_enabled` 是 OSS 中 `terraform.tfvars` 对应的持久配置，
默认均为关闭。切换前先合入并发布控制面 PR #148，完成 migration 0059，确认
目标 imageID、Ready 状态，以及 `tokenvolt_durable_jobs_queued` 和
`tokenvolt_durable_jobs_running{kind="dirty-partition"}` 可采集。

先检查集群的 `v1beta1.external.metrics.k8s.io` APIService 是否已存在及其 Helm
归属；已有其他提供者时不能启用本 chart 的 external metrics。配置
`tokenvolt_external_metrics_enabled=true` 后，先确认 APIService 为 Available，
并从 Kubernetes external metrics API 读取 ready、running 两个指标。再设置
`tokenvolt_archive_cutover_paused=true`，核对旧合并任务停下且无未完成租约，
最后设置 `tokenvolt_archive_dirty_worker.enabled=true` 并观察队列、运行中任务、
HPA 和 Worker 租约。确认新路径稳定后，再解除 cutover pause。每一步均通过
`make config-status` 检查 OSS 配置分歧，必要时查看 `make config-history`，
经单独部署授权后才执行 `make config-push`、`make plan`、`make start`。

这三个开关只完成部署配置接线；本 PR 不执行上述切换或验证线上指标。
