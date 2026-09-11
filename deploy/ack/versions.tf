terraform {
  required_version = ">= 1.8.0"

  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "= 1.292.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "= 3.2.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 2.38.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "= 3.7.2"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "= 4.1.0"
    }
  }
}
