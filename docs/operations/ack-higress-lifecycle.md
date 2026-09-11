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
