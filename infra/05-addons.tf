# addons.tf — Phase 6: EKS managed add-ons.
# Group A (before nodes): DaemonSets that go healthy with zero nodes; CNI set before bootstrap.
# addon_version is omitted → EKS installs the default version for the cluster's k8s version.

# --- Pod Identity Agent ---
# Vends AWS credentials to pods. Must exist before any pod_identity_association takes effect.
# Runs on host network, so it does not depend on the CNI.
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"
}

# --- VPC CNI (prefix delegation + Pod Identity) ---
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  # EKS self-installed the CNI at cluster creation; adopt it rather than conflict.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Grab /28 prefixes per allocation instead of single IPs → far higher pod density.
  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
    }
  })

  # The CNI's aws-node service account assumes the CNI role to make EC2 IP-management calls.
  pod_identity_association {
    role_arn        = aws_iam_role.cni.arn
    service_account = "aws-node"
  }

  depends_on = [aws_eks_addon.pod_identity_agent]
}

# --- kube-proxy ---
resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# ---------------------------------------------------------------------------
# Group B (after nodes): pod-based add-ons — depend on the node group so they
# schedule onto real nodes and come up healthy instead of Pending/DEGRADED.
# ---------------------------------------------------------------------------

# --- CoreDNS --- (EKS self-installed it at cluster creation → adopt with OVERWRITE)
resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.workers]
}

# --- Metrics Server --- (kubectl top + HPA; fresh install)
resource "aws_eks_addon" "metrics_server" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "metrics-server"

  depends_on = [aws_eks_node_group.workers]
}

# --- EBS CSI driver --- (provisions EBS volumes for PVCs; Pod Identity for its controller SA)
resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-ebs-csi-driver"

  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }

  depends_on = [
    aws_eks_node_group.workers,
    aws_eks_addon.pod_identity_agent,
  ]
}
