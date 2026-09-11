# Copyright 2026 alibaba
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

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
