#!/usr/bin/env bash
# pre-destroy.sh — clean up in-cluster resources that create AWS resources, BEFORE
# `terraform -chdir=infra destroy`, so nothing orphans (ALBs, NLBs, ENIs, EBS volumes).
#
# Strategy:
#   1. Delete the APP NAMESPACES → Kubernetes removes their objects in the right order:
#      pods terminate → Ingress/Gateway deleted (the live controller removes the ALBs + SGs
#      via finalizers) → PVCs finalize (the live EBS CSI driver deletes the volumes, gp3=Delete).
#   2. Sweep any STRAY Ingress/Gateway/LoadBalancer Services in other namespaces (e.g. a demo
#      left in `default`) that would also orphan an ALB.
#   3. Wait for the ELB ENIs to leave the VPC so `terraform destroy` can't race them.
#
# ⚠️ Must run while the cluster + controllers are ALIVE (before terraform destroy).
# ⚠️ Deleting the namespaces DELETES their data (EBS volumes are removed) — intended for teardown.
#
# Usage:  ./scripts/pre-destroy.sh          (then terraform -chdir=infra destroy)
# Override the namespace list: APP_NAMESPACES="production exchange dsp ssp" ./scripts/pre-destroy.sh
set -uo pipefail

REGION="${REGION:-eu-central-1}"
PROJECT="${PROJECT:-eks-dev}"
APP_NAMESPACES="${APP_NAMESPACES:-production exchange dsp ssp}"

kubectl get ns >/dev/null 2>&1 || { echo "kubectl can't reach the cluster — nothing to clean."; exit 0; }

echo "== deleting app namespaces (pods → Ingress/Gateway → PVCs; controllers clean ALBs + volumes) =="
for ns in $APP_NAMESPACES; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    echo "  delete namespace $ns"
    # --wait lets finalizers run: LB controller removes the ALB before the Ingress/Gateway
    # finalizer clears; CSI deletes the EBS volume before the PVC clears.
    kubectl delete namespace "$ns" --wait=true --timeout=300s \
      || echo "  ⚠️ namespace $ns delete timed out — a stuck finalizer? check: kubectl get ns $ns -o yaml"
  fi
done

echo "== sweeping stray LB resources in other namespaces (e.g. a demo in default) =="
purge() {
  kubectl get "$1" -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | while IFS=/ read -r ns name; do
        [ -n "$name" ] && echo "  delete $1 $ns/$name" && kubectl delete "$1" -n "$ns" "$name" --ignore-not-found >/dev/null
      done
}
purge ingresses
purge gateways.gateway.networking.k8s.io
kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | while IFS=/ read -r ns name; do
      [ -n "$name" ] && echo "  delete svc(LB) $ns/$name" && kubectl delete svc -n "$ns" "$name" --ignore-not-found >/dev/null
    done

# Wait for the controller to remove the ELB ENIs from the VPC (else destroy races them).
VPC="$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)"
if [ -n "$VPC" ] && [ "$VPC" != "None" ]; then
  echo "== waiting for ELB ENIs to clear from $VPC (up to 5 min) =="
  for i in $(seq 1 30); do
    n="$(aws ec2 describe-network-interfaces --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC" "Name=description,Values=ELB*" \
      --query 'length(NetworkInterfaces)' --output text 2>/dev/null)"
    [ "${n:-0}" = "0" ] && { echo "  ELB ENIs cleared."; break; }
    echo "  $n ELB ENI(s) remaining... ($i/30)"
    sleep 10
  done
fi

echo
echo "Done. Now safe to run:  terraform -chdir=infra destroy"
