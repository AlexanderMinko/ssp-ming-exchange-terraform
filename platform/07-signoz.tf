# 07-signoz.tf — Phase 13 step 2: the SigNoz stack for logs + traces, platform/ layer. Two charts:
#   1. `signoz`     the BACKEND (SigNoz on ClickHouse): stores and shows logs + traces
#   2. `k8s-infra`  the LOG AGENT: an otel-agent DaemonSet that ships pod logs to the backend (bottom of this file)
# Merged from 07 + 08 on 22/11/2026. Terraform orders them by reference (k8s-infra uses the signoz release's
# namespace), not by file or position.
#
# What the chart installs (namespace `signoz`), in data-flow order:
#   signoz-otel-collector   Deployment  OTLP ingest :4317 (gRPC) / :4318 (HTTP) → writes to ClickHouse
#   signoz-clickhouse       StatefulSet the columnar store for logs + traces (PVC 20Gi). It is NOT a
#                                       plain StatefulSet from the chart: the chart creates a
#                                       ClickHouseInstallation custom resource, and the bundled Altinity
#                                       clickhouse-operator turns it into the StatefulSet + Services.
#   signoz-zookeeper        StatefulSet coordination for ClickHouse (PVC 8Gi). SigNoz's schema uses
#                                       `ON CLUSTER` DDL, which needs ZooKeeper even with one node.
#   signoz-telemetrystore-migrator Job  creates/upgrades the ClickHouse tables, on every install/upgrade
#   signoz                  StatefulSet UI + query API :8080, its own settings in SQLite (PVC 1Gi)
#
# Why its own namespace (not `monitoring`): three PVCs, an operator and a migration Job — keeping them
# apart makes `kubectl get all,pvc -n signoz` show exactly this stack.
#
# ⚠️ Helm installs the chart's CRDs (ClickHouseInstallation & co.) on FIRST install only, same as VM.
#
# Retention (3 days, decided 16/11/2026) is NOT a chart value: SigNoz stores it as a setting and applies
# it as a ClickHouse table TTL. Set it once in the UI after install: Settings → General → Logs and Traces.

resource "helm_release" "signoz" {
  name             = "signoz" # = chart name → resource names stay short (signoz-clickhouse, signoz-otel-collector, …)
  repository       = "https://charts.signoz.io"
  chart            = "signoz"
  version          = "0.150.0" # SigNoz v0.150.0 — verify latest: helm show chart signoz --repo https://charts.signoz.io
  namespace        = "signoz"
  create_namespace = true
  timeout          = 900 # operator start → ClickHouse StatefulSet → 3 PVC binds; first install is slow

  values = [yamlencode({
    # Every PVC in the chart (ClickHouse, ZooKeeper, SigNoz SQLite) uses this class. gp3 is already the
    # cluster default, but naming it makes the dependency explicit (and creates the depends_on below).
    global = {
      storageClass = kubernetes_storage_class_v1.gp3.metadata[0].name
    }

    clickhouse = {
      # Requests = the measured upper bound (decided 23/11/2026). In the 22/11 load run (full tracing, 500 rps)
      # ClickHouse used ~540m CPU on average and 1.1 GB idle → 2.29 GB at peak, against 200m / 1Gi requested.
      # The scheduler places by requests, never by use, so it packed ClickHouse next to the bidders on a 2-vCPU
      # node that then sat at 100% CPU. With sampling 0.1 the real load is lower; these are the upper bound.
      # Capacity: with the apps' requests raised the same day (exchange 2 × 1000m, bidders 2 × 500m) this didn't fit on
      # 3 × t3.large; the node group has 4 since 23/11/2026 (infra/06-node-group.tf). Check for Pending pods after every apply.
      # No limit on purpose: ClickHouse sizes its caches from the memory it sees; a tight limit without
      # tuning max_server_memory_usage gets it OOM-killed. Prod would set both, tuned together.
      resources = {
        requests = {
          cpu    = "500m"
          memory = "2Gi"
        }
      }
      persistence = {
        size = "20Gi" # 3 days of pet-project logs + traces fit easily; gp3 allowVolumeExpansion if not
      }
    }

    # The OTLP collector: a safety valve for overload (decided 23/11/2026). The chart sets no memory limit and,
    # despite its values comment, no memory_limiter (its templates never generate one). In the 22/11 load run
    # ClickHouse fell behind, the exporters' sending queues grew to 5.3 GB, and the kubelet evicted the collector
    # under node memory pressure — on a node that also ran the exchange and mongodb-0.
    #   memory limit    the hard stop: above it the kernel kills the container (OOMKilled), the node stays safe
    #   memory_limiter  the brake below it: refuses new data (OTLP error → the apps' BatchSpanProcessor drops spans)
    #                   so the queues drain and the collector keeps running
    #   GOMEMLIMIT      Go's GC aims below this, so garbage doesn't push the heap toward the hard limit
    otelCollector = {
      resources = {
        requests = {
          cpu    = "100m"
          memory = "512Mi"
        }
        limits = {
          memory = "1Gi"
        }
      }
      additionalEnvs = {
        GOMEMLIMIT = "800MiB"
      }
      config = {
        processors = {
          memory_limiter = {
            check_interval         = "1s"
            limit_percentage       = 80 # of the container limit (1Gi): hard limit ~820 MiB, forces a GC above it
            spike_limit_percentage = 25 # soft limit = 80 − 25 = 55% (~560 MiB): refuse new data above it
          }
        }
        # memory_limiter must be FIRST: it has to refuse data before any other processor spends memory on it.
        # ⚠️ Helm replaces lists wholesale, so each list repeats the chart's default after memory_limiter
        # (signoz chart 0.150.0). Maps deep-merge, so receivers/exporters keep the chart's values.
        # On a chart upgrade: diff these lists against `helm show values signoz --version <new>`
        # (otelCollector.config.service.pipelines), or a new default processor is silently dropped.
        service = {
          pipelines = {
            traces = {
              processors = ["memory_limiter", "signozspanmetrics/delta", "signozspanmapper", "signozllmpricing", "filter/drop_stale", "batch"]
            }
            metrics = {
              processors = ["memory_limiter", "filter/drop_stale", "batch"]
            }
            logs = {
              processors = ["memory_limiter", "signozlogsnormalizer", "filter/drop_stale", "batch"]
            }
          }
        }
      }
    }
  })]

  # The LBC's mservice webhook gates every Service creation (see 05-argocd.tf); the PVCs need gp3.
  depends_on = [
    helm_release.aws_lbc,
    kubernetes_storage_class_v1.gp3,
  ]
}

# ClickHouse self-monitoring: a VMServiceScrape so vmagent pulls ClickHouse's health metrics into
# VictoriaMetrics (see the manifest for the why). A custom resource whose CRD comes from a Helm release
# in this same layer → kubernetes_manifest can't plan it; applied via kubectl like the GatewayClass.
resource "terraform_data" "clickhouse_scrape" {
  triggers_replace = { manifest = filesha256("${path.module}/manifests/clickhouse-vmservicescrape.yaml") }
  provisioner "local-exec" {
    command = "kubectl apply -f ${path.module}/manifests/clickhouse-vmservicescrape.yaml"
  }
  depends_on = [
    helm_release.signoz,                     # the namespace `signoz` and the metrics Service
    helm_release.victoria_metrics_k8s_stack, # the VMServiceScrape CRD and the vmagent that reads it
  ]
}

# ── 2. The LOG AGENT that feeds the backend above ──────────────────────────────────────────────────────────
#
# One DaemonSet `k8s-infra-otel-agent` = one OpenTelemetry Collector pod per node. Its logs pipeline:
#
#   filelog/k8s receiver   tails /var/log/pods/<ns>_<pod>_<uid>/<container>/<n>.log on ITS node
#                          (hostPath mount). The kubelet/containerd write every container's stdout there,
#                          so the apps change nothing — they just print.
#   container operator     strips the CRI prefix ("<time> stdout F ") and keeps the message
#   json/trace/severity    parse the app's JSON line; traceId/spanId → the record's trace_id/span_id
#   k8sattributes          asks the API server which pod owns the file → adds k8s.namespace.name,
#                          k8s.pod.name, k8s.deployment.name, … (that's what the ClusterRole is for)
#   resourcedetection      adds the node / cluster identity
#   otlphttp exporter      pushes batches to signoz-otel-collector:4318 → ClickHouse
#
# Logs only (decided 16/11/2026): node, kubelet and cluster METRICS stay in VictoriaMetrics, so those
# presets are off here — otherwise ClickHouse stores a second copy of what vmagent already scrapes.
# That also removes the second component (otel-deployment), which only exists for cluster metrics and
# k8s events.
#
# Not persisted: the read offsets. The chart has no file_storage extension, and start_at = end, so a
# restarted agent resumes at the END of each file — lines written while it was down are skipped.
# Prod adds file_storage on a hostPath; for learning it's a good thing to poke (see the plan).
#
# The agent also listens for OTLP on hostPort 4317/4318 on every node. Unused: the apps send traces
# straight to the SigNoz collector (decided 21/11/2026, like ssp-backend).

resource "helm_release" "signoz_k8s_infra" {
  name       = "k8s-infra"
  repository = "https://charts.signoz.io"
  chart      = "k8s-infra"
  version    = "0.17.1"                      # collector v0.139.0 — verify latest: helm show chart k8s-infra --repo https://charts.signoz.io
  namespace  = helm_release.signoz.namespace # same namespace as SigNoz; this reference also orders it after helm_release.signoz

  values = [yamlencode({
    clusterName = "eks-dev" # becomes the k8s.cluster.name attribute on every log line

    # Full URL with scheme: the otlphttp exporter needs http://. The chart passes the value through as-is.
    # In-cluster plain HTTP is fine for learning (otelInsecure = true is the chart default); prod would
    # use TLS or let the mesh (Phase 14) add mTLS.
    otelCollectorEndpoint = "http://signoz-otel-collector.signoz.svc.cluster.local:4318"

    presets = {
      # logsCollection: chart defaults except two things.
      # 1. A whitelist (decided 22/11/2026): only our business pods are collected; everything else is off by
      #    default. Entries are OR-ed and match the pod-name prefix in /var/log/pods/<ns>_<pod>_<uid>/, so this
      #    renders to include = *_exchange*_* and *_bidders*_*. Not `namespaces = ["production"]`: that would
      #    also take mongodb-0. A new service is added here. Filtering at the agent means other pods' lines
      #    never reach ClickHouse (a saved view in the UI would only hide them, still stored).
      # 2. The operator chain. A Helm list replaces the default list, so container-parser is repeated.
      #    The apps print one JSON object per line (logstash format). Without parsing, SigNoz stores that
      #    line as an opaque body, and the `traceId` inside it never links the log to its trace.
      logsCollection = {
        whitelist = {
          enabled    = true
          signozLogs = false # SigNoz's own pods stay out too
          pods       = ["exchange", "bidders"]
        }
        operators = [
          {
            id   = "container-parser" # chart default: strips the CRI prefix ("<time> stdout F ")
            type = "container"
          },
          {
            id         = "json-parser" # JSON lines only; a plain-text line passes through untouched
            type       = "json_parser"
            if         = "body startsWith \"{\""
            parse_from = "body"
            parse_to   = "attributes"
          },
          {
            id          = "time-parser" # the app's @timestamp becomes the record time (when it wrote the line)
            type        = "time_parser"
            if          = "attributes[\"@timestamp\"] != nil"
            parse_from  = "attributes[\"@timestamp\"]"
            layout_type = "gotime"
            layout      = "2006-01-02T15:04:05.000Z07:00"
          },
          {
            id   = "trace-parser" # MDC traceId/spanId (Micrometer Tracing) → the log record's trace_id/span_id
            type = "trace_parser"
            if   = "attributes.traceId != nil"
            trace_id = {
              parse_from = "attributes.traceId"
            }
            span_id = {
              parse_from = "attributes.spanId"
            }
          },
          {
            id         = "severity-parser" # logstash `level` → SigNoz severity (filter by ERROR in the UI)
            type       = "severity_parser"
            if         = "attributes.level != nil"
            parse_from = "attributes.level"
          },
          {
            id   = "service-name-to-resource" # the encoder's service_name → resource service.name (SigNoz's service)
            type = "move"
            if   = "attributes.service_name != nil"
            from = "attributes.service_name"
            to   = "resource[\"service.name\"]"
          },
          {
            id   = "message-to-body" # the readable message becomes the body; the rest stays as attributes
            type = "move"
            if   = "attributes.message != nil"
            from = "attributes.message"
            to   = "body"
          },
        ]
      }
      # kubernetesAttributes stays at its default. Switched off — VictoriaMetrics owns metrics:
      hostMetrics = {
        enabled = false
      }
      kubeletMetrics = {
        enabled = false
      }
      clusterMetrics = {
        enabled = false
      }
    }

    # The otel-deployment only runs clusterMetrics and k8s events; with both off it would idle.
    otelDeployment = {
      enabled = false
    }
  })]
}
