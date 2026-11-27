#!/usr/bin/env bash
# retrieve-passwords.sh — copy a chart-generated admin password to the macOS clipboard.
#
# WHY: Grafana and Argo CD generate their admin passwords at install time and keep them only in a cluster Secret,
# so every rebuild has new ones. This script reads the Secret and pipes the value straight into `pbcopy`:
# the password is never printed, so it stays out of the terminal scrollback (and out of any AI chat reading it).
#
# One service per run, because the clipboard holds one value.
#
# Usage:    ./scripts/retrieve-passwords.sh grafana|argocd
# Override: REGION=... CLUSTER=... ./scripts/retrieve-passwords.sh grafana
#
# ⚠️ kubectl targets the eks-dev context EXPLICITLY (found by cluster ARN), never the current context.
set -euo pipefail

REGION="${REGION:-eu-central-1}"
CLUSTER="${CLUSTER:-eks-dev}"

usage() {
  echo "Usage: $0 grafana|argocd" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
SERVICE="$1"

command -v pbcopy >/dev/null || { echo "ERROR: pbcopy not found (this script is for macOS)." >&2; exit 1; }

case "$SERVICE" in
  grafana)
    NAMESPACE="monitoring"
    SECRET="vm-grafana" # victoria-metrics-k8s-stack release `vm` (platform/06-monitoring.tf)
    KEY="admin-password"
    ;;
  argocd)
    NAMESPACE="argocd"
    SECRET="argocd-initial-admin-secret" # gone once you change the password in Argo CD and delete it
    KEY="password" # the UI is plain HTTP: server.insecure=true (platform/05-argocd.tf)
    ;;
  *)
    usage
    ;;
esac

CTX="$(kubectl config get-contexts -o name 2>/dev/null | grep -E "arn:aws:eks:${REGION}:[0-9]+:cluster/${CLUSTER}$" | head -1 || true)"
if [[ -z "$CTX" ]]; then
  echo "ERROR: no kubeconfig context for cluster/$CLUSTER — run ./scripts/update-kubeconfig.sh (or the cluster is down)." >&2
  exit 1
fi

# Read into a variable, check it, then copy. Never echo it.
if ! VALUE="$(kubectl --context "$CTX" -n "$NAMESPACE" get secret "$SECRET" -o jsonpath="{.data.${KEY}}" 2>/dev/null)" \
  || [[ -z "$VALUE" ]]; then
  echo "ERROR: secret $NAMESPACE/$SECRET (key $KEY) not found or empty." >&2
  echo "       Is the cluster up and the chart installed? kubectl --context $CTX -n $NAMESPACE get secret" >&2
  exit 1
fi
printf '%s' "$VALUE" | base64 -d | pbcopy
unset VALUE

echo "Copied the $SERVICE admin password to the clipboard (user: admin)."

# The laptop port lives ONLY in ssp-ming-mcp/ports.json (section `eks`, same key as $SERVICE); never hardcode it here.
# ssp-ming-mcp/scripts/eks-port-forward.sh opens the forward. No file or no entry → skip the hint, the copy still worked.
PORTS_JSON="$(cd "$(dirname "$0")/../.." && pwd)/ssp-ming-mcp/ports.json"
LOCAL_PORT="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["eks"][sys.argv[2]]["localPort"])' \
  "$PORTS_JSON" "$SERVICE" 2>/dev/null || true)"
if [[ -n "$LOCAL_PORT" ]]; then
  echo "Open http://localhost:$LOCAL_PORT (needs ssp-ming-mcp/scripts/eks-port-forward.sh running)."
fi
