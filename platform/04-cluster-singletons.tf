# 04-cluster-singletons.tf — cluster-scoped, shared, one-per-cluster resources.
# NOT app-shaped → they live here (platform/), never in an app Helm chart.
#
# gp3 StorageClass is a CORE k8s type → native kubernetes_storage_class_v1 (declarative, drift-aware).
# GatewayClass + ClusterSecretStore are CRs whose CRDs are created IN THIS layer (Gateway API CRDs /
# ESO Helm), so kubernetes_manifest can't plan them (CRD absent at plan time) — applied via kubectl
# (terraform_data), same pattern as the CRD install, and idempotent (adopts an existing object).

resource "kubernetes_namespace_v1" "app" {
  for_each = toset(var.app_namespaces)
  metadata {
    name = each.value
  }
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name        = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }
  storage_provisioner    = "ebs.csi.aws.com" # EBS CSI driver (infra/ add-on)
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}

# GatewayClass 'alb' — the Gateway API engine registration (its CRD comes from 02-gateway-api-crds.tf).
resource "terraform_data" "gatewayclass" {
  triggers_replace = { manifest = filesha256("${path.module}/manifests/gatewayclass.yaml") }
  provisioner "local-exec" {
    command = "kubectl apply -f ${path.module}/manifests/gatewayclass.yaml"
  }
  depends_on = [terraform_data.gateway_api_crds]
}

# ClusterSecretStore 'aws-secretsmanager' — shared ESO store (its CRD comes from the ESO Helm chart).
resource "terraform_data" "clustersecretstore" {
  triggers_replace = { manifest = filesha256("${path.module}/manifests/clustersecretstore.yaml") }
  provisioner "local-exec" {
    command = "kubectl apply -f ${path.module}/manifests/clustersecretstore.yaml"
  }
  depends_on = [helm_release.eso]
}

# Shared edge — ONE Gateway (= one ALB) that all apps attach HTTPRoutes to (infra-owned).
# App charts contribute only HTTPRoutes; this is the single per-cluster entry point.
resource "terraform_data" "shared_gateway" {
  triggers_replace = { manifest = filesha256("${path.module}/manifests/shared-gateway.yaml") }
  provisioner "local-exec" {
    command = "kubectl apply -f ${path.module}/manifests/shared-gateway.yaml"
  }
  depends_on = [
    terraform_data.gatewayclass, # the GatewayClass (→ Gateway API CRDs)
    helm_release.aws_lbc,        # the controller that provisions the ALB
  ]
}
