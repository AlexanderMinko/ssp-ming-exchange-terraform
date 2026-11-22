# variables.tf — knobs for the load generator. All have defaults, so the layer runs standalone.

variable "project" {
  description = "Project tag and name prefix. Same value as the cluster layers, so cost reports group together."
  type        = string
  default     = "eks-dev"
}

variable "region" {
  description = "Same region as the cluster, so latency measures the exchange, not the internet."
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment tag."
  type        = string
  default     = "dev"
}

variable "instance_type" {
  description = "Compute-optimized, non-burstable. c7g = Graviton (arm64). Switching to c7i (x86) also needs ami_architecture = \"x86_64\"."
  type        = string
  default     = "c7g.xlarge"
}

variable "ami_architecture" {
  description = "Must match instance_type: arm64 for c7g, x86_64 for c7i."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.ami_architecture)
    error_message = "ami_architecture must be arm64 or x86_64."
  }
}

variable "root_volume_gib" {
  description = "Root disk. JDK + sbt/ivy caches + Gatling simulation.log of a long run fit in 30 GiB."
  type        = number
  default     = 30
}

