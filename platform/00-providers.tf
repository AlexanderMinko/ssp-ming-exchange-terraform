# providers.tf — platform/ layer: in-cluster resources (Helm charts, k8s objects).
# Runs AFTER infra/ (the cluster must already exist) — this resolves the Helm-provider
# chicken-and-egg by looking the cluster up instead of creating it here.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    helm       = { source = "hashicorp/helm", version = "~> 2.0" } # v2: stable nested `kubernetes {}` block
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
  }

  # Separate state key from infra/ — same bucket, different object.
  backend "s3" {
    bucket       = "ominko-eks-tfstate-eu-central-1"
    key          = "eks/platform/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.cluster_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Look up the EXISTING cluster created by the infra/ layer (endpoint + CA cert).
data "aws_eks_cluster" "main" {
  name = var.cluster_name
}

# Auth token comes from `aws eks get-token`, run fresh on every call (exec plugin),
# because EKS tokens are short-lived and would expire if fetched once.
provider "kubernetes" {
  host                   = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
    }
  }
}
