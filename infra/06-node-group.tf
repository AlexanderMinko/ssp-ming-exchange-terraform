# node-group.tf — Phase 7: managed node group (the worker nodes).

resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-workers"
  node_role_arn   = aws_iam_role.node.arn

  # Private subnets only → nodes get no public IPs; egress via NAT, no inbound from internet.
  subnet_ids = [for s in aws_subnet.private : s.id]

  instance_types = ["t3.medium"]
  ami_type       = "AL2023_x86_64_STANDARD" # required — AL2 AMIs gone from k8s 1.33+
  disk_size      = 20                       # GB, EBS root volume per node

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }
  # No lifecycle ignore_changes[desired_size]: that's only for the Cluster Autoscaler.
  # Karpenter (later) provisions nodes directly and won't fight this static group.

  # Nodes must bootstrap AFTER the CNI (prefix delegation) is set, so max-pods is computed right.
  depends_on = [
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
    aws_eks_addon.pod_identity_agent,
  ]
}
