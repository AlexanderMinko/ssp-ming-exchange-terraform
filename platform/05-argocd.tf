# 05-argocd.tf — Phase 12.4: install Argo CD (the GitOps "pull" engine), platform/ layer.
#
# Argo CD runs IN the cluster, watches a git repo (your config repo), and continuously reconciles
# the cluster to match it. Terraform installs Argo CD; Argo CD then manages your WORKLOADS — not
# itself. That's the clean division: Terraform owns the platform, Argo CD owns the apps.

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.2.1" # Argo CD v3.4.5 — verify latest: helm search repo argo/argo-cd --versions
  namespace        = "argocd" # REQUIRED — without it Helm defaults to the "default" namespace
  create_namespace = true     # Helm creates/owns the namespace

  values = [yamlencode({
    configs = {
      params = {
        # Serve the API/UI over plain HTTP instead of self-signed HTTPS. Safe here because access
        # is ONLY via `kubectl port-forward` to localhost. It's also the correct setting once Argo CD
        # sits behind the ALB with ACM TLS (ALB terminates TLS, talks HTTP to the backend) — the same
        # pattern your app uses. Revisit if you ever expose the argocd-server Service directly.
        "server.insecure" = true
      }
    }
  })]

  # SAME lesson as ESO (03-eso.tf): the LB Controller's `mservice.elbv2.k8s.aws` webhook
  # (failurePolicy=Fail, empty namespaceSelector) gates EVERY Service creation cluster-wide.
  # Argo CD creates Services, so it must not install until the controller is Ready — otherwise
  # the webhook has no endpoints and the install fails mid-way.
  depends_on = [helm_release.aws_lbc]
}

# Argo CD root Application (App-of-Apps) — the BOOTSTRAP SEAM. Terraform creates ONLY this one
# Application; it points Argo CD at the config repo's argocd/apps/, and every child app + workload
# cascades from git. Its CRD comes from the Argo CD Helm release above, so it's applied via
# terraform_data + kubectl (kubernetes_manifest can't plan a CR whose CRD is absent at plan time) —
# same pattern as gatewayclass/clustersecretstore. root-app.yaml carries its own namespace (argocd).
resource "terraform_data" "argocd_root" {
  triggers_replace = { manifest = filesha256("${path.module}/manifests/root-app.yaml") }
  provisioner "local-exec" {
    command = "kubectl apply -f ${path.module}/manifests/root-app.yaml"
  }
  depends_on = [helm_release.argocd]
}


