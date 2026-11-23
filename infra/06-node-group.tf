# node-group.tf — Phase 7: managed node group (the worker nodes).

resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-workers"
  node_role_arn   = aws_iam_role.node.arn

  # Private subnets only → nodes get no public IPs; egress via NAT, no inbound from internet.
  subnet_ids = [for s in aws_subnet.private : s.id]

  instance_types = ["t3.large"]             # 2 vCPU / 8 GiB. Phase 13 (16/11/2026): ClickHouse (SigNoz) + VictoriaMetrics don't fit on t3.medium
  ami_type       = "AL2023_x86_64_STANDARD" # required — AL2 AMIs gone from k8s 1.33+
  disk_size      = 20                       # GB, EBS root volume per node

  scaling_config {
    # 4 × t3.large (23/11/2026, was 3 since Phase 13): 7.72 cores / 32 GiB allocatable-ish. After the 22/11 load run
    # the requests were raised to match real use (exchange 2–3 × 1000m, bidders 2 × 500m, ClickHouse 500m / 2Gi), and
    # 3 nodes (5.79 cores allocatable) could no longer hold them: a pod that doesn't fit stays Pending (no autoscaler).
    # Changing desired_size is an in-place ASG update: one node is added, the running nodes and pods aren't touched.
    desired_size = 4
    min_size     = 3
    max_size     = 5 # caps only an autoscaler (none yet); desired must stay <= max, so a 5th node needs both
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
