<!--
Copyright 2026 alibaba

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# TokenVolt 控制面与数据面共享 CLB

2026-09-13：启用分离入口；`ack.tokenvolt.net` 直达控制面，`api.tokenvolt.net` 进入自部署 Higress。两个域名仍共享公网 CLB，使用各自的后端组。

2026-09-21：`www.tokenvolt.net` 从原包年 ECS 的门户切到 ACK 控制面的 `tokenvolt-ack-control-plane` 组，与 `ack.tokenvolt.net` 同一个后端。

2026-09-26：公司站点使用单副本 ACK Deployment 和保留型云盘 PVC；启用 `tokenvolt_site_public_enabled` 后，`www.tokenvolt.net` 根规则改指向独立的 `tokenvolt-ack-site` 组，`ack.tokenvolt.net` 继续提供登录和控制面。DNS、CLB 和证书不变。

## 配置归属

`ecs_public_sites` 非空时启用共享入口。公网 CLB、80→443 跳转、HTTPS/SNI 证书引用、各域名规则、DNS 和虚拟服务器组由本目录的 OpenTofu/Terraform 管理，生命周期不依赖 `lifecycle_mode`。

| 域名 | 后端 | 成员管理者 |
| --- | --- | --- |
| www.tokenvolt.net | 公司站点 Service:4192（启用站点切换前仍为控制面） | ACK CCM |
| newapi.tokenvolt.net | 原包年 ECS:3000 | Terraform |
| ack.tokenvolt.net | TokenVolt 控制面 HTTP Service:8000 | ACK CCM |
| api.tokenvolt.net | Higress HTTP Service:80 | ACK CCM |

控制面和 Higress 的 Service 使用同一 CLB ID、`force-override-listeners=false` 和 `vgroup-port=<各自专用组 ID>:<服务端口>`。CCM 只增删自身后端，跟踪节点/Pod 扩缩容；不会管理或删除公网监听。Higress Service 仅暴露 HTTP 80，TLS 在 CLB 终止。控制面的 Allowed Origin 和 Secure Cookie 仍按公网 HTTPS 配置，公网 Ingress 不再挂内部测试证书，避免重复 TLS 重定向。

### 同一控制面服务多个门户域名

公司站点切换前，`www.tokenvolt.net` 与 `ack.tokenvolt.net` 指向同一个控制面组，浏览器地址栏是哪个域名，请求带的 `Origin` 就是哪个。控制面的同源校验（`requireOrigin`）覆盖凭据、账单、客户生命周期、定价等写接口，按 `ALLOWED_ORIGIN` 精确匹配：

- 只列 `ack` 时，www 上「能登录、能读，所有写接口 403」。
- 只列 `www` 时，反过来让 ack 全站写操作 403。
- 因此 `ALLOWED_ORIGIN` 支持逗号分隔多值，由 `tokenvolt_extra_allowed_origins` 追加，例如 `https://ack.tokenvolt.net,https://www.tokenvolt.net`。

公司站点上线顺序：先启用 `tokenvolt_site_enabled`，确认 Pod、PVC、`/api/health` 和 CLB 后端健康；再启用 `tokenvolt_site_public_enabled`。回滚只关闭后一个开关，`www` 即恢复到 `ecs_public_sites_on_ack` 选择的控制面或原 ECS 后端。旧 `/demo` 是一次性人工规则，切换确认后通过 SLB API 删除，不纳入新的回滚路径。

官方复用机制：[跨集群复用负载均衡与服务器组](https://help.aliyun.com/zh/ack/ack-managed-and-ack-dedicated/user-guide/use-the-ccm-to-deploy-services-across-clusters)。这里没有将原 ECS 和 ACK 混入同一后端组。

## 纳管已有入口

不要用空 state 执行 apply。先取回同一套 `terraform.tfstate`、`terraform.tfvars`，备份并限制文件权限，再恢复所需云身份和 GHCR 凭据。文件、计划文件及明文计划 JSON 可能包含数据库密码、MFA 密钥、Registry 凭据和证书私钥，均不得提交 GitHub。

在本地 tfvars 中配置（具体 ID 从现有 CLB 查询）：

```hcl
ecs_public_sites = {
  www = {
    domain         = "www.tokenvolt.net"
    instance_id    = "<原包年 ECS ID>"
    port           = 8000
    certificate_id = "<www 的 CLB RSA 证书 ID>"
    health_path    = "/readyz"
  }
  newapi = {
    domain         = "newapi.tokenvolt.net"
    instance_id    = "<原包年 ECS ID>"
    port           = 3000
    certificate_id = "<newapi 的 CLB RSA 证书 ID>"
    health_path    = "/api/status"
  }
}
ecs_default_site = "newapi"
ack_edge_certificate_id = "<ack 的 CLB RSA 证书 ID>"

# www 已由 ACK 控制面提供服务；ECS 组保留可回滚。
ecs_public_sites_on_ack = ["www"]
# 仅在发布能解析列表的控制面镜像后设置，否则精确匹配会失配：
# tokenvolt_extra_allowed_origins = ["https://www.tokenvolt.net"]
```

先导入已经存在的资源，不能创建重复 DNS、监听或服务器组。资源地址与导入 ID 格式如下：

| Terraform 地址 | 导入 ID |
| --- | --- |
| `alicloud_slb_server_group.ecs["www"]`、`["newapi"]` | 对应 rsp-... |
| `alicloud_slb_listener.public_https[0]` | lb-...:https:443 |
| `alicloud_slb_listener.public_http[0]` | lb-...:http:80 |
| `alicloud_slb_rule.ecs["www"]`（非默认站点） | 已存在的 rule-...；原来不存在的规则正常创建 |
| `alicloud_slb_domain_extension.ecs["www"]`（非默认站点） | 对应 de-... |
| `alicloud_alidns_record.ecs["www"]`、`["newapi"]` | 对应 DNS RecordId |

推荐使用临时 import block，先 plan 一次，再执行审查过的计划，避免逐资源导入中断造成误判。listener ID 必须包含协议。纳管后移除临时 import 文件即可；保留 state 中的资源记录。

### 保留插件凭据，避免恢复死锁

`higress-system` namespace 和 `tokenvolt-ghcr` Secret 必须先于 Higress Helm 就绪，且 stop 不删除它们。否则保留的 WasmPlugin 会在 Gateway 启动时引用不存在的凭据，而 Helm 又等待 Gateway Ready，形成启动死锁。迁移已有环境时补充导入：

```shell
tofu import kubernetes_namespace_v1.higress higress-system
tofu import 'kubernetes_secret_v1.tokenvolt_registry_higress[0]' higress-system/tokenvolt-ghcr
```

只在对应资源已存在且未在 state 时导入；新部署正常创建即可。凭据通过原 Secret 安全复用，不能复制到文档或终端输出。

### OCI 插件校验值的含义

Higress 对 `oci://` 的 `spec.sha256` 校验所选平台的 manifest digest，不是镜像索引 digest，也不是裸 `plugin.wasm` 的文件哈希。对于本环境现有 policy 发布物，独立下载并逐层验算得到：

- URL 固定的 OCI index：`fd2fa753a3111619b7e5c14d3951eaf9e0b125b99ac62f48310794ba35968ce9`。
- linux/amd64 manifest（应填入本版本的 `tokenvolt_policy_plugin_sha256`）：`2ade98fae0f36127bb15fb084973ea9c7a771085996d066e719cb6310f7005b3`。
- 镜像内 `plugin.wasm` 文件：`eb8c8edb528f1161b847fc33bf31321919671e3992e8d577f1b54d700d735ed7`。

旧 tfvars 中的 `7f7f89...` 会触发校验失败，应与版本一起更新。不能关闭校验来绕过该问题。后续换架构或换镜像需重新核验，不能照抄本版本值。参考 [Higress Wasm 镜像获取实现](https://github.com/higress-group/istio/blob/istio-1.27/pkg/wasm/imagefetcher.go) 与 [缓存校验实现](https://github.com/higress-group/istio/blob/istio-1.27/pkg/wasm/cache.go)。

## 启停和发布

首次恢复先分别审查两阶段的 plan：

```shell
tofu init
tofu plan -var='lifecycle_mode=starting' -out=starting.tfplan
# 检查：不重建现有 CLB、DNS、ECS、RDS、随机密钥；现有监听无替换。
tofu apply starting.tfplan
tofu plan -var='lifecycle_mode=running' -out=running.tfplan
# 检查：恢复 Helm 应用及扩缩容配置，不改变原 ECS 站点的后端。
tofu apply running.tfplan
```

后续仍可使用 `make start` / `make stop`，但这些目标会自动批准，所以配置或版本修改后应优先使用上述 plan/apply 步骤。恢复后继续使用同一份最新 state，不能再覆盖回同事提供的旧快照。在线版本升级保持 `lifecycle_mode=running`，不要把 start 当作日常升级命令。

`stop` 只移除 ACK 工作负载并归零节点。原 ECS 站点、公网监听、域名规则和证书绑定仍存在；控制面和数据面的独立服务器组变空时，两个 ACK 域名停止服务，不影响另外两个域名。`prevent_destroy` 防止误删 ECS 入口；下线它们必须单独评审修改。

## 验证计划

1. `tofu fmt -check`、`tofu validate`；渲染 Helm Service，检查只保留 80，明确禁止覆盖监听并引用专用组。
2. 导入后的 starting/running 计划不能替换 CLB、原站点 DNS/监听/服务器组或已有应用密钥。
3. 节点 Ready；Higress、TokenVolt 和依赖 Pod 可用；Service 的实际注解与方案一致，CCM 只把 ACK 成员放入专用组。
4. 通过正常 DNS/TLS 请求四个域名，验证首页、登录页、静态资源、`/readyz` 或 `/api/status`，以及 HTTP→HTTPS 跳转。
5. ACK `/readyz` 必须同时验证 HEAD/GET；独立 CLB 规则无法单独设置 GET 健康方法。New API 明确继承默认 HTTPS 监听的 GET 健康检查，不使用 HEAD。
6. 未携带 Key 的 API 域名 `/v1/models` 应由数据面拒绝；再做授权 Key 的推理及门户完整验收属于业务验收，不能用健康检查代替。
7. 实际确认后端健康状态；最后 plan 应无意外变更。只预览 stopped 计划，确认不会删除共享入口，不为了验证而停止线上环境。

## 证书、回退与边界

CLB 使用 RSA 证书。共享模式必须提供 `ack_edge_certificate_id`，不将测试 CA 证书作为公网默认方案。state 中原有测试 CA 和内部 TLS Secret 保留，不重置。证书续期与更新 CLB 需要运维流程，本模块引用外部证书 ID，不会自动续期外部证书。

恢复异常时先保持原 ECS 两个域名不动，修复 ACK 后端。必要时只将 ACK 工作负载退回停止状态。不得直接恢复旧的 `force-override-listeners=true` 部署文件并运行 start，这会重新引入监听覆盖。

## 分离入口的部署和迁移

共享入口启用时设置：

```hcl
tokenvolt_split_public_entry = true
tokenvolt_public_host = "ack.tokenvolt.net"
tokenvolt_data_public_host = "api.tokenvolt.net"
tokenvolt_data_certificate_id = "<api 域名的可信 CLB RSA 证书 ID>"
```

控制面的 Allowed Origin 仍为 `https://ack.tokenvolt.net`；模型路由发布器的公网 Host 改为 `api.tokenvolt.net`。启用分离入口后不创建门户 Ingress，控制面通过 `tokenvolt-control-plane-public` Service 直接接入专用后端组。Higress 不再接受 ack 的模型路由，也不为 api 提供门户兜底页面。

数据规则的健康检查直接探测每个 Gateway 后端的 `15020/healthz/ready`，而非调用控制面或通过另一个 Gateway 代理健康响应。15020 不新增公网监听。CLB 使用 HTTP/1.0 探测，Envoy 的 15021 端口会返回 426，因此选择已验证支持 HTTP/1.0 的本 Pod agent 15020 端口。控制面独立检查 `/readyz`。

**首次迁移必须分阶段，不能用一次未经验证的全量 apply 代替迁移验证：**

1. 私有备份 state/tfvars、旧网关配置和 DNS，记录旧记录 TTL。先配置新后端组和 Service，确认 CCM 注册正确端点，检查已有模型/Key/额度配置未变化。
2. 配置域名证书、转发规则及应用域名。ack 规则依赖应用 Helm 就绪；API DNS 依赖证书、数据规则和 Helm。由于 provider 无法证明公网业务链路正确，DNS 必须留到独立验收后的计划中，首次不要提前纳入 DNS 资源。
3. 通过固定解析到 CLB、但保留 `api.tokenvolt.net` SNI/Host 的请求，验证真实 TLS、普通/SSE/客户端中断请求、未授权模型与无 Key 拒绝、用量日志。确认 www/NewAPI 正常。
4. 将原 API DNS RecordId 导入 `alicloud_alidns_record.model_api[0]`，只更新该记录，避免并存 A/CNAME。再做正常 DNS 下的全套验证。
5. 至少等待原 TTL，检查旧网关的有效模型请求、默认域名和内部调用依赖。处理遗留控制面和历史测试 Key 后，才能删除 Serverless；保留账单与历史日志，不删除共享 SLS、NAT、ECS 或 RDS。
6. 重新 plan，确认无漂移；将配置、证书引用和验收证据一并提交。

HTTPS 默认站点直接由监听器承接。默认站点不额外创建域名转发规则/SNI，避免浪费有限的附加域名证书配额；删除历史重复 SNI 前必须先移除对应重复规则，确认默认后端和默认证书相同。其余 ECS 规则/SNI 保留删除保护。

回退时在旧网关尚未删除的窗口内恢复 API 的原 CNAME；控制面直连可以独立保留。已经删除 Serverless 后不能仅回退 DNS，应从私有备份重新建立旧网关或修复自部署入口。不要覆盖最新 state 为旧快照。

本地 Helm Chart 文件哈希作为 release values 的一部分；仅修改模板也会触发 Helm 升级，不需要修改业务镜像或伪造版本。
