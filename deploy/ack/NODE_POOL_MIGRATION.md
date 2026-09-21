# ACK 节点池迁移

目标拓扑：2 台包年包月节点作为常驻保障池；按量节点池保持 `min=0`、
`max=10`，仅在 Pod 无法调度时由 ACK 自动扩容。

先 review 并 apply OpenTofu。确认新保障池的两台节点均为 `Ready` 后，执行：

```shell
export KUBECONFIG=/path/to/ack-kubeconfig
deploy/ack/scripts/migrate-to-baseline-pool.sh --execute
```

脚本先将原按量节点全部 cordon，再逐台 drain，并等待 `kube-system`、
`higress-system`、`tokenvolt-system` 的 Deployment 恢复。成功后不删除按量
节点池；ACK Cluster Autoscaler 会把空节点缩到 0，以后仍可从 0 扩容。

脚本失败时会重新 uncordon 原节点，不会修改节点池或 Terraform state。
