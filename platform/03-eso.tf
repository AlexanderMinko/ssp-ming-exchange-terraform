# 03-eso.tf — Phase 11.1: External Secrets Operator (IAM + Helm), platform/ layer.
# ESO syncs AWS Secrets Manager → native k8s Secrets, authenticating via Pod Identity
# (its OWN service account — no auth block in the ClusterSecretStore; see the CR manifests).

# Look up the out-of-band-created secret so we scope IAM to its EXACT ARN (never "*").
# Requires the secret to already exist (create it first — Step 1).
data "aws_secretsmanager_secret" "mongodb" {
  name = "eks-dev/exchange/mongodb"
}

# Pod Identity role for ESO (reuses local.pod_identity_trust from 01-lb-controller.tf).
resource "aws_iam_role" "eso" {
  name               = "${var.cluster_name}-eso-role"
  assume_role_policy = local.pod_identity_trust
}

# Read-only, scoped to EXACTLY the mongodb secret — never Resource: "*".
resource "aws_iam_role_policy" "eso" {
  name = "eso-secretsmanager-read"
  role = aws_iam_role.eso.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = data.aws_secretsmanager_secret.mongodb.arn
    }]
  })
}

# Bind the role to ESO's controller service account (created by the Helm chart below).
resource "aws_eks_pod_identity_association" "eso" {
  cluster_name    = var.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso.arn
}

# Install ESO. The chart also installs the ClusterSecretStore/ExternalSecret CRDs (installCRDs=true).
resource "helm_release" "eso" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "2.8.0" # pinned (tag helm-chart-2.8.0)
  namespace        = "external-secrets"
  create_namespace = true

  # No IRSA service-account annotation — Pod Identity provides creds via the association above.
  # Also depend on the LB Controller: its `mservice.elbv2.k8s.aws` webhook (failurePolicy=Fail,
  # empty namespaceSelector) gates EVERY Service creation cluster-wide. ESO creates a Service, so
  # if the controller isn't Ready yet the webhook has no endpoints and ESO's install fails. This
  # forces ESO to wait until the LBC release is fully rolled out (helm wait=true) → webhook serving.
  depends_on = [
    aws_eks_pod_identity_association.eso,
    helm_release.aws_lbc,
  ]
}
