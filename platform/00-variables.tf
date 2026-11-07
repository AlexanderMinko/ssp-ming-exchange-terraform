# variables.tf — platform/ layer inputs. Mirror the infra/ layer's values.

variable "cluster_name" {
  description = "Name of the EKS cluster this layer installs into (created by infra/)."
  type        = string
  default     = "eks-dev"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment tag."
  type        = string
  default     = "dev"
}

variable "app_namespaces" {
  description = "Namespaces the platform pre-creates for app workloads."
  type        = list(string)
  default     = ["production", "edge"]
}
