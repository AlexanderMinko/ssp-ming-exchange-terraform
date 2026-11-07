# variables.tf — the knobs for this cluster. Change these to rebuild it differently
# without editing any resource code. All have defaults, so the layer runs standalone;
# add a terraform.tfvars only when a secret or per-environment override appears.

variable "cluster_name" {
  description = "Name of the EKS cluster. Also used as a prefix for IAM roles and in resource tags."
  type        = string
  default     = "eks-dev"
}

variable "region" {
  description = "AWS region to deploy into. Frankfurt."
  type        = string
  default     = "eu-central-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /16 gives 65,536 addresses, carved into /20 subnets later."
  type        = string
  default     = "10.0.0.0/16"

  # Reject a malformed CIDR at plan time instead of failing mid-apply against AWS.
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block, e.g. 10.0.0.0/16."
  }
}

variable "availability_zones" {
  description = "AZs to spread subnets across. Hardcoded (not data-sourced) so the AZ layout is explicit."
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
}

variable "kubernetes_version" {
  description = "EKS control plane version. Kept as a variable so a version bump is a one-line change."
  type        = string
  default     = "1.34"
}

variable "environment" {
  description = "Environment tag applied to all resources (via provider default_tags)."
  type        = string
  default     = "dev"
}

variable "github_repo" {
  description = "GitHub repo (owner/name) allowed to assume the Actions role, e.g. \"ominko/ssp-exchange\". No default: only you know it — set it in terraform.tfvars."
  type        = string
  default     = "AlexanderMinko@60578360/SSP-Exchange@1306765118"
}
