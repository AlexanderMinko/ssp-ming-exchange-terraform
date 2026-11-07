# 02-gateway-api-crds.tf — install the Kubernetes Gateway API CRDs via Terraform.
#
# CRDs are vendored into platform/crds/ (downloaded + committed) rather than fetched from
# URLs at apply time: pinned, reviewable in git, works offline, updates are deliberate.
# We still shell out to kubectl (terraform_data + local-exec) because Terraform has no clean
# native way to apply multi-document CRD YAML. --server-side avoids the client-side
# "annotations too long" error that large CRDs hit.
#
# NOTE: after a cluster rebuild, run ./scripts/update-kubeconfig.sh first so kubectl
# points at the new cluster before applying this layer.
#
# To bump versions: re-download the two files below and commit — the content-hash trigger
# re-runs the apply automatically.

resource "terraform_data" "gateway_api_crds" {
  # Re-apply only when a vendored CRD file's CONTENT changes.
  triggers_replace = {
    standard = filesha256("${path.module}/crds/gateway-api-standard.yaml") # upstream Gateway API v1.5.0
    aws      = filesha256("${path.module}/crds/aws-gateway-crds.yaml")     # AWS controller v3.4.2
  }

  provisioner "local-exec" {
    command = "kubectl apply --server-side -f ${path.module}/crds/"
  }
}
