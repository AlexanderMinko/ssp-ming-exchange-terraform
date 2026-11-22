# 06-monitoring.tf — Phase 13 step 1: metrics stack (VictoriaMetrics), platform/ layer.
# Stack changed 16/11/2026 from kube-prometheus-stack to Start.io's: VictoriaMetrics for metrics,
# SigNoz for logs and traces (a later file).
#
# Two releases, in order:
#   1. prometheus-operator-crds — only the CRD definitions (ServiceMonitor, PodMonitor, …), no operator.
#   2. victoria-metrics-k8s-stack — the VM operator plus the custom resources it reconciles:
#        VMSingle  → one vmsingle pod: the TSDB (storage + PromQL/MetricsQL query API on :8428)
#        VMAgent   → one vmagent pod: scrapes targets, remote-writes to vmsingle
#        VMServiceScrape / VMNodeScrape → what vmagent scrapes (kubelet, cAdvisor, KSM, node-exporter, …)
#      plus Grafana, kube-state-metrics and node-exporter as plain subcharts.
#
# Same pattern as the LBC and ESO: you declare a custom resource, a controller makes it real.
# You never edit a scrape config file in the cluster.

# Why a separate CRD release: the app charts (exchange, bidders) ship a Prometheus-format
# `ServiceMonitor`. The VM operator CONVERTS each ServiceMonitor into a VMServiceScrape, but it does
# not install the ServiceMonitor CRD. Without this release the API server doesn't know the kind,
# and Argo CD fails the app sync with "no matches for kind ServiceMonitor".
resource "helm_release" "prometheus_operator_crds" {
  name             = "prometheus-operator-crds"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "prometheus-operator-crds"
  version          = "33.0.2" # prometheus-operator v0.95.2 — verify latest: helm show chart prometheus-operator-crds --repo https://prometheus-community.github.io/helm-charts
  namespace        = "monitoring"
  create_namespace = true
}

# ⚠️ Helm installs a chart's crds/ folder on FIRST install only and never upgrades it. Before bumping
# `version`, apply the new chart's VM CRDs yourself (kubectl apply --server-side), then upgrade.
resource "helm_release" "victoria_metrics_k8s_stack" {
  name             = "vm" # short: subcharts are named after the release (vm-grafana, vm-kube-state-metrics, …)
  repository       = "https://victoriametrics.github.io/helm-charts/"
  chart            = "victoria-metrics-k8s-stack"
  version          = "0.98.1" # VictoriaMetrics v1.156.0, operator chart 0.68.x — verify latest: helm show chart victoria-metrics-k8s-stack --repo https://victoriametrics.github.io/helm-charts/
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 600 # CRDs + operator start + a PVC bind on first install can exceed the 300 s default

  values = [yamlencode({
    # Pins the VM custom resource names: VMSingle `vm` → Service `vmsingle-vm` (:8428),
    # VMAgent `vm` → Service `vmagent-vm`. KEDA (Phase 15) and Grafana point at vmsingle-vm.
    fullnameOverride = "vm"

    # Off until there's a receiver (Slack/email). Without vmalert no alert rules are evaluated.
    # Turn on vmalert first when you want to see rules firing, Alertmanager when you want to route them.
    alertmanager = {
      enabled = false
    }
    vmalert = {
      enabled = false
    }

    # EKS runs the control plane for you: etcd, the scheduler and the controller-manager are not
    # reachable from inside the cluster. Left on, their scrape targets are permanently DOWN.
    kubeEtcd = {
      enabled = false
    }
    kubeScheduler = {
      enabled = false
    }
    kubeControllerManager = {
      enabled = false
    }

    vmsingle = {
      spec = {
        # VM units: d/w/y, and a bare number means MONTHS. The chart default "1" = 1 month.
        retentionPeriod = "7d"

        # requests = what the SCHEDULER reserves on a node. Without them vmsingle is a
        # BestEffort pod: first to be evicted under memory pressure.
        resources = {
          requests = {
            cpu    = "200m"
            memory = "512Mi"
          }
        }

        # One gp3 EBS volume via the EBS CSI driver (Phase 6.4). RWO is right: one vmsingle pod.
        # VM compresses ~10× better than Prometheus, so 10Gi is plenty for 7 days here.
        storage = {
          storageClassName = kubernetes_storage_class_v1.gp3.metadata[0].name
          accessModes      = ["ReadWriteOnce"]
          resources = {
            requests = {
              storage = "10Gi"
            }
          }
        }
      }
    }

    # vmagent keeps the chart defaults: selectAllByDefault = true, so it picks up EVERY
    # VMServiceScrape/VMPodScrape in every namespace — including the ones converted from the
    # apps' ServiceMonitors in `production`. No `release:` label needed (unlike kube-prometheus-stack).

    # No adminPassword here ON PURPOSE: TF state is plaintext in S3. Unset → the Grafana chart
    # generates a random password into the Secret `vm-grafana`.
    # No persistence: dashboards come from ConfigMaps, so a restart loses nothing
    # you didn't hand-edit in the UI. Access via kubectl port-forward for now.
    #
    # Dashboards (decided 22/11/2026): the repo ssp-ming-monitoring is their source. Argo CD
    # (argocd/apps/grafana-dashboards.yaml in the helm repo) renders one ConfigMap per dashboard into
    # `monitoring` with the label grafana_dashboard=1, which the sidecar below already watches (chart
    # default). The two values here add FOLDERS: the sidecar writes each ConfigMap into the
    # subdirectory named by its `grafana_folder` annotation, and the provider turns subdirectories
    # into Grafana folders. Helm deep-merges maps, so the chart's other sidecar defaults stay.
    grafana = {
      persistence = {
        enabled = false
      }
      sidecar = {
        dashboards = {
          folderAnnotation = "grafana_folder"
          provider = {
            foldersFromFilesStructure = true
          }
        }
      }
    }
  })]

  # The LBC's mservice webhook gates every Service creation (see 05-argocd.tf); the PVC needs gp3;
  # the ServiceMonitor CRD must exist before the operator starts, or it skips the converter watch.
  depends_on = [
    helm_release.aws_lbc,
    kubernetes_storage_class_v1.gp3,
    helm_release.prometheus_operator_crds,
  ]
}
