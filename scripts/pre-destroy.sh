#!/usr/bin/env bash
# pre-destroy.sh — clean up in-cluster resources that own AWS resources, BEFORE any `terraform destroy`,
# so nothing orphans (ALBs + target groups + security groups, ENIs, EBS volumes).
#
# Why it's needed: those AWS resources are created by in-cluster CONTROLLERS (LB controller, EBS CSI driver),
# not by Terraform. Terraform can't delete what it never created, and once the cluster is gone the controllers
# that could are gone too. `helm uninstall` doesn't help either: it leaves a StatefulSet's PVCs (ClickHouse,
# ZooKeeper, Mongo) behind on purpose.
#
# Steps (each needs the controllers ALIVE, so run this first):
#   1. Stop Argo CD's application controller → self-heal can't recreate what we delete.
#   2. Delete the OPERATOR-managed custom resources while their operators still run. VMSingle/VMAgent (VM operator)
#      and ClickHouseInstallation (Altinity operator) carry finalizers only their operator removes. Delete the
#      namespace first and the operator pod can die before the CR → the namespace hangs in Terminating forever.
#   3. Delete the namespaces → pods stop, PVCs finalize (EBS CSI deletes the volumes; gp3 reclaimPolicy=Delete).
#   4. Sweep Gateways/Ingresses/LoadBalancer Services anywhere (the shared Gateway lives in `edge`) → the LB
#      controller deletes the ALB, its target groups and security groups.
#   5. Wait until the ELB ENIs and the PVC volumes are really gone (both are asynchronous).
#
# ⚠️ DESTRUCTIVE: deletes the namespaces' data (Mongo, metrics, logs, traces). Intended for teardown only.
# ⚠️ kubectl targets the eks-dev context EXPLICITLY (found by cluster ARN), never the current context — a
#    kubeconfig pointing at another cluster must not get its namespaces deleted.
#
# Teardown order:   ./scripts/pre-destroy.sh
#                   terraform -chdir=platform destroy
#                   terraform -chdir=infra destroy
#                   ./scripts/verify-destroyed.sh
# Override: NAMESPACES="production monitoring signoz" REGION=... CLUSTER=... ./scripts/pre-destroy.sh
set -uo pipefail

REGION="${REGION:-eu-central-1}"
CLUSTER="${CLUSTER:-eks-dev}"
PROJECT="${PROJECT:-eks-dev}"
# production = apps + Mongo PVC (Argo CD); monitoring = vmsingle PVC; signoz = ClickHouse, ZooKeeper, SQLite PVCs.
# exchange/dsp/ssp = a possible future namespace split; skipped when absent.
NAMESPACES="${NAMESPACES:-production monitoring signoz exchange dsp ssp}"

CTX="$(kubectl config get-contexts -o name 2>/dev/null | grep -E "arn:aws:eks:${REGION}:[0-9]+:cluster/${CLUSTER}$" | head -1)"
if [ -z "$CTX" ]; then
  echo "No kubeconfig context for cluster/$CLUSTER — run ./scripts/update-kubeconfig.sh (or the cluster is already gone)."
  exit 1
fi
k() { kubectl --context "$CTX" "$@"; }
if ! k get ns >/dev/null 2>&1; then
  echo "Context $CTX can't reach the cluster — stale after a rebuild (./scripts/update-kubeconfig.sh) or already destroyed."
  exit 1
fi
echo "Target: $CTX"

echo
echo "== 1. stopping Argo CD's application controller (no self-heal during teardown) =="
if k get statefulset argocd-application-controller -n argocd >/dev/null 2>&1; then
  k scale statefulset argocd-application-controller -n argocd --replicas=0 >/dev/null && echo "  scaled to 0"
else
  echo "  not installed — skipped"
fi

echo
echo "== 2. deleting operator-managed resources while their operators still run =="
delete_crs() { # $1 = comma-separated resource kinds; skipped quietly if a CRD isn't installed
  local kind
  for kind in ${1//,/ }; do
    k get crd "$kind" >/dev/null 2>&1 || continue
    if [ -n "$(k get "$kind" -A --no-headers 2>/dev/null)" ]; then
      echo "  delete $kind (all namespaces)"
      k delete "$kind" -A --all --wait=true --timeout=300s >/dev/null \
        || echo "  ⚠️ $kind delete timed out — is its operator running? check: kubectl get $kind -A"
    fi
  done
}
# Altinity: the ClickHouse StatefulSet + PVC hang off this CR.
delete_crs "clickhouseinstallations.clickhouse.altinity.com"
# VictoriaMetrics: storage + scraper first, then the scrape objects.
delete_crs "vmsingles.operator.victoriametrics.com,vmagents.operator.victoriametrics.com,vmalerts.operator.victoriametrics.com,vmalertmanagers.operator.victoriametrics.com"
delete_crs "vmservicescrapes.operator.victoriametrics.com,vmpodscrapes.operator.victoriametrics.com,vmnodescrapes.operator.victoriametrics.com,vmrules.operator.victoriametrics.com"

echo
echo "== 3. deleting namespaces (pods → PVCs; the EBS CSI driver deletes the volumes) =="
for ns in $NAMESPACES; do
  if k get ns "$ns" >/dev/null 2>&1; then
    echo "  delete namespace $ns"
    # --wait lets finalizers run: the CSI driver deletes each EBS volume before its PVC clears.
    k delete namespace "$ns" --wait=true --timeout=300s >/dev/null \
      || echo "  ⚠️ namespace $ns delete timed out — a stuck finalizer? check: kubectl get ns $ns -o yaml"
  fi
done

echo
echo "== 4. sweeping LB resources in every namespace (the shared Gateway is edge/shared) =="
purge() {
  k get "$1" -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | while IFS=/ read -r ns name; do
        [ -n "$name" ] && echo "  delete $1 $ns/$name" && k delete "$1" -n "$ns" "$name" --ignore-not-found --wait=true --timeout=180s >/dev/null
      done
}
purge gateways.gateway.networking.k8s.io
purge ingresses
k get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | while IFS=/ read -r ns name; do
      [ -n "$name" ] && echo "  delete svc(LB) $ns/$name" && k delete svc -n "$ns" "$name" --ignore-not-found >/dev/null
    done

echo
echo "== 5. waiting for AWS to catch up =="
VPC="$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)"
if [ -n "$VPC" ] && [ "$VPC" != "None" ]; then
  # ELB ENIs left in the VPC make `terraform destroy` fail on the subnets/VPC.
  for attempt in $(seq 1 30); do
    n="$(aws ec2 describe-network-interfaces --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC" "Name=description,Values=ELB*" \
      --query 'length(NetworkInterfaces)' --output text 2>/dev/null)"
    [ "${n:-0}" = "0" ] && { echo "  ELB ENIs cleared."; break; }
    echo "  $n ELB ENI(s) remaining... ($attempt/30)"
    sleep 10
  done
fi

# PVC volumes: the CSI driver detaches, then deletes — usually under a minute after the PVC goes.
for attempt in $(seq 1 30); do
  vols="$(aws ec2 describe-volumes --region "$REGION" --filters "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null)"
  [ -z "${vols//[[:space:]]/}" ] && { echo "  PVC volumes deleted."; break; }
  echo "  volume(s) remaining: $vols ($attempt/30)"
  sleep 10
done

echo
echo "Done. Next, in this order:"
echo "  terraform -chdir=platform destroy"
echo "  terraform -chdir=infra destroy"
echo "  ./scripts/verify-destroyed.sh"
