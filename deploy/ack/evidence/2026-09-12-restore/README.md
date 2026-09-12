# 2026-09-12 ACK 恢复与共享入口验收

验证时间：北京时间 10:31–10:33。操作目标是纳管原 ECS 两个站点，并恢复同事原 ACK 控制面和自建 Higress。使用原 state 和 tfvars，不是重建环境。

## 结果

| 项目 | 结果 |
| --- | --- |
| ACK 节点 | 2 个 Ready，原节点池 ecs.u1-c1m2.xlarge，按量工作节点恢复运行 |
| Higress | Controller 2/2；Gateway 观测时 3/3，副本数由原 HPA 管理 |
| 控制面 | 1/1 Ready，恢复原 v0.2.0-ack.3 对应固定镜像 digest |
| 监控、fixture | collector、adapter 和原 model mock 就绪 |
| 三个域名 | 正常 DNS 均访问 39.96.173.140；首页/登录页/静态资源 200，HTTPS 证书验证成功 |
| 健康检查 | www `/readyz`、newapi `/api/status`、ack `/readyz` 返回 200；ACK HEAD `/readyz` 也为 200 |
| 公网协议 | 三个 HTTP 入口均 302 跳转到对应 HTTPS 域名 |
| 匿名鉴权边界 | ACK `/v1/models` 和 `/api/v1/auth/session` 均返回 401 |
| CLB 后端 | ECS 两个端口和三个 ACK 网关端点均 normal |
| 运行计划 | 最后 running plan 无变更 |
| 停止预览 | 仅预览 stopped plan：共享 CLB/监听/域名规则/DNS/服务器组/镜像凭据均 no-op；未执行停止 |
| 旧状态保护 | 原 database password、MFA master key 和 API key pepper 与原 state 比对一致；没有 RDS 重建操作 |

没有新购 CLB、EIP 或 RDS；原 ACK 节点池自动恢复了 2 台按量工作节点，继续产生原规格运行费用。包年 ECS 保留。新签发 ACK RSA 证书有效期至 2026-12-11；证书引用已纳入部署，自动续期仍需运维配置。

## 修复的恢复阻塞

1. **共享入口监听冲突**：旧 Service 强制覆盖 80/443。改为 Terraform 管理入口、CCM 显式复用 ACK 专用组并只维护成员；ECS 入口跨 ACK stop 保留。
2. **插件拉取凭据依赖死锁**：原 registry Secret 等待 Higress Ready，但保留插件需要先获得该 Secret。namespace 与 Secret 改为持久资源，Higress 明确依赖它们；本轮安全复制原凭据后导入 state。
3. **OCI 校验值错误**：固定镜像的 index、linux/amd64 manifest、裸 Wasm 文件三种 digest 不同。独立校验镜像与每层内容，并按实际 Higress OCI 校验语义改为 manifest `2ade98...`；没有关闭校验。
4. **80 跳转监听导入的 Provider 默认值**：第一次 apply 报 `IdleTimeout` 无效；补足有效 timeout 配置后重新读取与计划确认无差异，实际 302 跳转通过。
5. **测试证书替换顺序**：先更新 ACK 的 SNI 绑定到可信 RSA 证书，再清理本轮创建的临时测试证书。最终共享模式要求传入可信证书 ID，避免继续依赖该临时 fallback。

恢复期间初次 ACK 请求曾返回 502，发生于控制面未启动、健康状态尚未收敛阶段；最终请求与健康状态均已复测。最初误探测未注册的 `/api/session` 得到 404，按源码校正为 `/api/v1/auth/session` 后确认返回预期 401，该 404 不作为会话鉴权测试。

## 证据与验证方式

- `three-hosts-final-check.json`：独立 ECS 通过正常 DNS 请求，记录各页面/资源状态、证书校验结果和实际目标 IP；不携带账号或 Key。
- `auth-boundary-final.json`：正确会话接口和 OpenAI 目录接口的匿名请求。
- `final-health.json`：CLB 后端最终健康快照。
- `workloads.json`：实际节点、Deployment Ready 副本和镜像。
- `terraform-checks.json`、`stopped-preview-summary.json`：运行无变更、停止不影响入口的检查摘要。

执行了 `tofu fmt -check`、`tofu validate`、`git diff --check`。使用最终 plan 的 Higress values 执行 `helm template ... --show-only templates/service.yaml`，核对只保留 80、force-override=false、vgroup-port 指向专用组；再回读实际 Service 和 CLB 成员交叉验证。

配置审查：Spec 轴没有发现额外阻断；Standards 轴指出跨变量 validation 不兼容所声明的 Terraform 1.8，已去除该跨引用。持久 namespace/Secret 的依赖顺序单独复审通过。Provider 对旧 `servers` 字段有弃用提示，本次固定版本 1.292.0 下已验证有效；后续升级 Provider 前需迁移到独立 attachment 资源。

原始 plan、完整 state、tfvars、KubeConfig 和 Registry/证书凭据均存放于操作者受限本地目录，不在本仓库。这里仅保留不含凭据的检查摘要。

## 验收边界

本轮完成基础环境和公网入口恢复，不等同于完整客户业务验收：未使用管理员密码登录、未创建客户或 Key、未调用付费上游模型、未验证账单对账或极限性能。原账号/策略未人为重置，具体登录、用量、授权 Key 和真实模型能力应在后续验收中验证。

`api.tokenvolt.net` 仍在原 Serverless 网关。三个 Web 域名已共享本 CLB，但不代表生产推理入口已切换到自建 Higress。
