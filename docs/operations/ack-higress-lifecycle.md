<!--
Licensed to the Apache Software Foundation (ASF) under one or more
contributor license agreements.  See the NOTICE file distributed with
this work for additional information regarding copyright ownership.
The ASF licenses this file to you under the Apache License, Version 2.0
(the "License"); you may not use this file except in compliance with
the License.  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# ACK Higress lifecycle

Run all commands from `deploy/ack`. Keep the local `terraform.tfvars` and
OpenTofu state; both contain environment-specific or sensitive data.

## 共享公网入口

如果当前 CLB 同时承载 `www.tokenvolt.net` 和 `newapi.tokenvolt.net`，必须保留
`ecs_public_sites` 配置以及最新 state。参见 [共享入口部署与纳管说明](../../deploy/ack/SHARED_PUBLIC_EDGE.md)。
共享模式由 Terraform 管理监听与域名规则，ACK CCM 只管理 Higress 后端成员。
不要恢复旧的 `force-override-listeners=true` 配置；那会覆盖原 ECS 的在线入口。

## Start

The first phase restores one worker, and the second enables autoscaling and
installs Higress, observability, and TokenVolt.

```shell
export TF_VAR_tokenvolt_ghcr_token='<GitHub token with read:packages>'
make start
```

## Check current state

```shell
tofu output -raw lifecycle_mode
KUBECONFIG=/private/tmp/tokenvolt-ack-kubeconfig kubectl get nodes
KUBECONFIG=/private/tmp/tokenvolt-ack-kubeconfig kubectl get pods -A
```

Healthy service state is `running`. A transitional `starting` or `stopping`
means the second OpenTofu apply was interrupted; rerun `make start` or
`make stop` respectively.

## Stop test workloads

The first phase removes the Helm workloads. The second disables node
autoscaling and sets the node-pool desired size to zero.

```shell
make stop
```

Normal stop preserves the ACK control plane, node pool/scaling group, RDS,
SLS, OSS, CLB, DNS, certificates, administrator password, and MFA secret.
`make destroy` is a separate full teardown and is not part of routine stop.

## 应用升级记录

[2026-09-12 渠道与模型重构发布](2026-09-12-tokenvolt-channel-release.md)：固定镜像、EnvoyFilter 权限、数据库迁移、逐实例 Wasm 生效检查及 GHCR 下载超时处理。升级不能只检查控制面发布状态，必须核对每个网关实例的实际配置和鉴权结果。
