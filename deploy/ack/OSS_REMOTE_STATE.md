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
镜像的 Plan 会按原有安全校验失败。

`plan/start/stop` 执行前会比较本地、OSS 和上次同步版本：

- OSS 较新且本地未修改：自动拉取；
- 本地已修改且 OSS 未变化：使用本地配置；
- 两边都修改：停止执行，要求人工合并；
- `start/stop` 成功后：自动把本地 `terraform.tfvars` 同步到 OSS；
- Apply 失败：不会覆盖 OSS 中的有效配置。

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
