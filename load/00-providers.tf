# providers.tf — the "load" layer: one EC2 instance that runs Gatling (ssp-ming-publishers)
# against the exchange through the public ALB. Separate state from infra/ and platform/,
# so `terraform destroy` here removes only the load generator and never touches the cluster.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Same bucket as the other layers, own key. Literals only: the backend is read before variables.
  backend "s3" {
    bucket       = "ominko-eks-tfstate-eu-central-1"
    key          = "eks/load/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      Component   = "load-generator"
      ManagedBy   = "terraform"
    }
  }
}
