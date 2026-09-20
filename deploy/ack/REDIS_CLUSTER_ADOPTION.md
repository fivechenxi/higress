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

# Redis 出站集群纳管与部署前置检查

本变更只补齐 Helm 的托管 Redis 出站集群定义；不重建 Redis，不修改凭据、模型路由或客户额度。提交 PR 不授权部署。

## 配置来源

`tokenvolt.tf` 从托管实例派生 Redis 主机与 `<host>.dns` serviceName，端口与插件共用。模板从 serviceName 去掉最后一个 `.dns` 得到实际 DNS 地址，不另设硬编码实例地址。集群名必须为 `outbound|<port>||<serviceName>`。无密码进入 EnvoyFilter。

- 托管 DNS Redis + rateLimits.enabled：生成唯一的 tokenvolt-quota-redis-cluster。
- Kubernetes Redis：不额外 ADD 集群，仍由 Kubernetes 服务发现提供；切换模式前需运行验证，模板测试不证明该运行链路健康。
- rateLimits 关闭或切换回 Kubernetes Redis：不生成该资源。已纳管后 Helm 升级可能删除旧资源，因此必须先核对仍引用它的插件/客户策略，不能将模式切换当成无风险配置清理。
- 托管 DNS 地址和内置 Redis 同时开启：渲染失败；OpenTofu 既有模式互斥检查仍保留。

## 已有手工资源的一次性接管（待部署窗口授权）

9/19 只读检查发现线上同名 EnvoyFilter 由 kubectl-client-side-apply 创建，没有 Helm release 归属。直接升级可能失败，不允许先删除再重建，也不使用不加区分的强制接管。

1. 按 OSS_REMOTE_STATE.md 获取权威配置和精确部署基线；本地旧 tfvars/state 不作为依据。审阅 OpenTofu plan，不夹带镜像、数据库、Redis 实例或客户策略变更。
2. 安全备份现有 EnvoyFilter（含 metadata/resourceVersion）和旧 Helm 发布版本。只读核对是否出现新所有者/第三方修改；如有停止协调。排查其他 EnvoyFilter/McpBridge 是否已提供同名 cluster，避免重复 ADD。
3. 使用真实配置受控渲染，仅提取本 EnvoyFilter 比较 spec：namespace、selector、cluster name、实际 endpoint、port 必须一致。完整 Helm 渲染可能含秘密，不得输出到 PR/共享日志。
4. 单独授权后，对**同一现有对象**采用 resourceVersion 条件更新所有权 metadata：`app.kubernetes.io/managed-by=Helm`、`meta.helm.sh/release-name=tokenvolt`、`meta.helm.sh/release-namespace=tokenvolt-system`（实际值先核对）。spec 不变；这一步不是本 PR 自动执行内容。
5. 再执行已审阅的部署。Helm atomic/rollback 对首次接管资源的删除行为须在隔离环境验证；metadata 接管后到 release 成功前为显式风险窗口。失败时先检查对象是否仍存在且 spec 未变，必要时从精确备份恢复；不得直接 uninstall 或删除重建。
6. 成功后核对 Helm 归属和对象内容，逐个网关检查唯一 cluster、HEALTHY endpoint 和 Redis 初始化错误，再使用隔离客户执行 200→429。禁止 Redis FLUSHDB、客户数据清理或真实客户策略变更。

## 验证范围

本 PR 提供 Helm 渲染红/绿回归，不声称完成真实网关运行验证或 Helm 接管演练。部署前仍须验证以上接管/回退流程和两个网关的执行链路，结果另行记录。

2026-09-19 本地结果：macOS arm64、Python 3.14、PyYAML 6.0.3、Helm v4.2.4。
在基线 `bef39897` 上先加入回归用例，9 项测试中 2 项失败：应有出站集群但实际 0 个，以及托管/内置模式混用未拒绝。添加模板后相同 9 项通过；补充空主机校验后，整个 ACK test_*.py 共 18 项通过。命令（在安装 PyYAML 的隔离 Python 环境中运行）：

```sh
PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s deploy/ack/tests -p 'test_*.py'
git diff --check
```

测试值只含合成域名/凭据，测试仅调用本地 helm template；没有启动 Kubernetes/Envoy、创建云资源或加载真实秘密。该结果证明渲染缺口修复，不替代上游规则要求的运行证据。真实网关红/绿及首次接管/失败回退演练仍待完成，审核方应保留为部署门槛。

控制面历史补档：[PR #70](https://github.com/TokenVolt-ai/tokenvolt-control-plane/pull/70)。旧 Deployment patch 已被 quotaEnabled 模板替代，不恢复；旧静态 Redis 清单不是本部署入口。
