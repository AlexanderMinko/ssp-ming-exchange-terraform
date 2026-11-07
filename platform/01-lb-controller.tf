# lb-controller.tf — Phase 8: AWS Load Balancer Controller, fully in the platform/ layer.
# The whole component lives together: its IAM (role/policy/association) + the Helm install.

# Trust for Pod Identity roles created in this layer.
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

# --- IAM ---
resource "aws_iam_policy" "lbc" {
  name   = "${var.cluster_name}-lbc-policy"
  policy = file("${path.module}/policies/aws-lbc-iam-policy.json")
}

resource "aws_iam_role" "lbc" {
  name               = "${var.cluster_name}-lbc-role"
  assume_role_policy = local.pod_identity_trust
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

# cluster_name comes from the variable (no aws_eks_cluster resource in this layer).
resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn
}

# --- Helm install ---
resource "helm_release" "aws_lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.4.2" # chart 3.4.2 → controller v3.4.2 (Gateway API L7 needs ≥ v2.14.0)
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "vpcId"
    value = data.aws_eks_cluster.main.vpc_config[0].vpc_id
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  # Enable the Gateway API (L7 / ALB) controller — off by default.
  set {
    name  = "controllerConfig.featureGates.ALBGatewayAPI"
    value = "true"
  }

  # Pod Identity mapping must exist (creds), and the Gateway API CRDs must be installed
  # before this controller starts with ALBGatewayAPI=true — else it errors watching them.
  depends_on = [
    aws_eks_pod_identity_association.lbc,
    terraform_data.gateway_api_crds,
  ]
}
