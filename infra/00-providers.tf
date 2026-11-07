# providers.tf — Terraform settings, provider pinning, and remote state backend.
# This is the "infra" layer: all AWS-provider resources (VPC → IAM → EKS → nodes → add-ons).
# In-cluster Helm/Kubernetes resources live in a separate "platform" layer with its own state.

terraform {
  # Pin Terraform itself. >= 1.10 is required for native S3 state locking (use_lockfile).
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0" # allow 5.x, block a breaking 6.x major bump
    }
  }

  # Remote state in S3. Values here MUST be literals — the backend is read before
  # Terraform evaluates variables, so `var.*` is not allowed in this block.
  backend "s3" {
    bucket       = "ominko-eks-tfstate-eu-central-1"
    key          = "eks/infra/terraform.tfstate" # path INSIDE the bucket; namespaces this layer
    region       = "eu-central-1"
    encrypt      = true # encrypt the state object at rest (SSE)
    use_lockfile = true # native S3 lock object — no DynamoDB table needed (TF >= 1.10)
  }
}

provider "aws" {
  region = var.region

  # Stamped onto every resource this configuration creates — makes cost tracking
  # and `terraform destroy` cleanup reliable (nothing goes untagged / orphaned).
  default_tags {
    tags = {
      Project     = var.cluster_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
