# iam.tf — Phase 3: IAM roles.
# Each role = a trust policy (WHO may assume it) + attached permission policies (WHAT it can do).

# --- Cluster role ---
# Assumed by the EKS control plane so AWS can manage cluster-owned resources
# (ENIs in your subnets, security groups, load balancers) on your behalf.
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"

  # Trust policy: WHO may assume this role → the EKS service itself.
  assume_role_policy = jsonencode({
    Version = "2012-10-17" # the IAM policy language version — always this date string
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" } # the service principal allowed to assume
      Action    = "sts:AssumeRole"                  # the act of assuming the role
    }]
  })
}

# Permission policy: WHAT the role can do → AWS-managed set for a control plane.
resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- Node role ---
# Assumed by the worker EC2 instances (via an auto-created instance profile) so the
# kubelet and node agents have the AWS permissions they need.
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" } # nodes ARE EC2 instances
      Action    = "sts:AssumeRole"
    }]
  })
}

# Three managed policies, attached in one for_each over a set of ARNs.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",         # join the cluster
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",              # CNI: ENIs + pod IPs (see note — overlaps Pod Identity)
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly", # pull images from ECR
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# --- Pod Identity roles (for add-ons) ---
# Trust policy shared by every Pod Identity role: the pod principal, plus BOTH
# sts:AssumeRole AND sts:TagSession (Pod Identity tags the session — omit it and creds fail).
locals {
  pod_identity_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

# VPC CNI — manages ENIs and assigns pod IPs. Associated with the CNI add-on in Phase 6.
resource "aws_iam_role" "cni" {
  name               = "${var.cluster_name}-cni-role"
  assume_role_policy = local.pod_identity_trust
}

resource "aws_iam_role_policy_attachment" "cni" {
  role       = aws_iam_role.cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy" # corrected: no such "..._IPv4Policy"
}

# EBS CSI driver — creates/attaches EBS volumes for PVCs. Associated with the add-on in Phase 6.4.
resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-role"
  assume_role_policy = local.pod_identity_trust
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy" # note the service-role/ path
}
