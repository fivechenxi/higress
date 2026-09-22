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

# ai-proxy Wasm

The ACK deployment can select an immutable ai-proxy through
`tokenvolt_ai_proxy_plugin_url` and `tokenvolt_ai_proxy_plugin_sha256`. Existing
defaults remain unchanged until both values are explicitly updated in the
OSS-managed `terraform.tfvars`.

Build and verify the artifact containing SSE framing fix `dc099932` without
changing OSS or ACK:

```shell
make ai-proxy-artifact
```

After release approval, publish the checksum-addressed object once:

```shell
make ai-proxy-artifact-publish
```

The publish command verifies the pinned source commit, runs the provider/SSE
regression tests, builds with Go 1.24.4, checks the Wasm SHA-256, uploads it to
OSS and downloads it again for byte verification. It does not run OpenTofu or
Helm. After upload,
set the following in the shared `terraform.tfvars`, then run `make config-push`
and review `make plan` before apply:

```hcl
tokenvolt_ai_proxy_plugin_url = "https://tokenvolt-plugins-1150088752341921-cn-beijing.oss-cn-beijing.aliyuncs.com/ai-proxy/sha256/6efb1e275e1f92979d03cd864a0779a1382c3ce2ee8d743c5bd43f3ef7d2294d.wasm"
tokenvolt_ai_proxy_plugin_sha256 = "6efb1e275e1f92979d03cd864a0779a1382c3ce2ee8d743c5bd43f3ef7d2294d"
```
