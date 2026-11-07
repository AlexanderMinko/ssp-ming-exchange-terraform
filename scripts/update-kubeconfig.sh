#!/usr/bin/env bash
# update-kubeconfig.sh — repoint kubectl at the current cluster.
# Run after every `terraform destroy` + `apply`: EKS assigns a NEW API endpoint on
# each rebuild, so the cached kubeconfig goes stale ("dial tcp ... no such host").
# Override defaults with env vars: CLUSTER=... REGION=... ./scripts/update-kubeconfig.sh
set -uo pipefail

REGION="${REGION:-eu-central-1}"
CLUSTER="${CLUSTER:-eks-dev}"

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
echo
kubectl get nodes
