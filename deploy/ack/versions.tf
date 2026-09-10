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
  }
}
