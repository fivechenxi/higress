resource "kubernetes_horizontal_pod_autoscaler_v2" "controller" {
  count = var.lifecycle_mode == "running" ? 1 : 0

  metadata {
    name      = "higress-controller"
    namespace = "higress-system"
  }

  spec {
    min_replicas = 2
    max_replicas = 3

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = "higress-controller"
    }

    metric {
      type = "Resource"

      resource {
        name = "cpu"

        target {
          type                = "Utilization"
          average_utilization = 65
        }
      }
    }

    behavior {
      scale_up {
        stabilization_window_seconds = 0
        select_policy                = "Max"

        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 60
        }

        policy {
          type           = "Pods"
          value          = 2
          period_seconds = 60
        }
      }

      scale_down {
        stabilization_window_seconds = 300
        select_policy                = "Max"

        policy {
          type           = "Percent"
          value          = 25
          period_seconds = 60
        }
      }
    }
  }

  depends_on = [helm_release.higress]
}

resource "kubernetes_pod_disruption_budget_v1" "controller" {
  count = var.lifecycle_mode == "running" ? 1 : 0

  metadata {
    name      = "higress-controller"
    namespace = "higress-system"
  }

  spec {
    min_available = "1"

    selector {
      match_labels = {
        app = "higress-controller"
      }
    }
  }

  depends_on = [helm_release.higress]
}

resource "kubernetes_pod_disruption_budget_v1" "gateway" {
  count = var.lifecycle_mode == "running" ? 1 : 0

  metadata {
    name      = "higress-gateway"
    namespace = "higress-system"
  }

  spec {
    min_available = "1"

    selector {
      match_labels = {
        app = "higress-gateway"
      }
    }
  }

  depends_on = [helm_release.higress]
}
