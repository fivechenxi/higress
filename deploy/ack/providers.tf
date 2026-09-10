provider "alicloud" {
  region  = var.region
  profile = var.alicloud_profile
}

data "alicloud_cs_cluster_credential" "this" {
  cluster_id                 = alicloud_cs_managed_kubernetes.this.id
  temporary_duration_minutes = 60
}

locals {
  kubeconfig  = yamldecode(data.alicloud_cs_cluster_credential.this.kube_config)
  kubecluster = local.kubeconfig.clusters[0].cluster
  kubeuser    = local.kubeconfig.users[0].user
}

provider "helm" {
  kubernetes = {
    host                   = local.kubecluster.server
    cluster_ca_certificate = base64decode(local.kubecluster["certificate-authority-data"])
    client_certificate     = base64decode(local.kubeuser["client-certificate-data"])
    client_key             = base64decode(local.kubeuser["client-key-data"])
  }
}

provider "kubernetes" {
  host                   = local.kubecluster.server
  cluster_ca_certificate = base64decode(local.kubecluster["certificate-authority-data"])
  client_certificate     = base64decode(local.kubeuser["client-certificate-data"])
  client_key             = base64decode(local.kubeuser["client-key-data"])
}
