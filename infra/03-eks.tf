# eks.tf — Phase 4: the EKS control plane (the managed Kubernetes brain).

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    # Control-plane cross-account ENIs live in the private subnets (control plane ↔ node traffic).
    subnet_ids              = [for s in aws_subnet.private : s.id]
    endpoint_private_access = true # in-VPC traffic reaches the API server privately
    endpoint_public_access  = true # kubectl from your laptop (still authenticated)
    # public_access_cidrs   = ["<your-ip>/32"]  # optional: lock the public endpoint to your IP only
  }

  access_config {
    authentication_mode                         = "API"  # access entries API, not the aws-auth ConfigMap
    bootstrap_cluster_creator_admin_permissions = true   # give the creating identity (you) cluster-admin
  }

  # role_arn depends on the role, but NOT on its policy attachment. The control plane needs
  # AmazonEKSClusterPolicy attached before creation, so state that dependency explicitly.
  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}
