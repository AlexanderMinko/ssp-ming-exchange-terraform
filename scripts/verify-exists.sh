#!/usr/bin/env bash
# verify-exists.sh — read-only check that the whole infra is CREATED and HEALTHY.
# Inverse of verify-destroyed.sh. Two sections: AWS-API checks, then (if the cluster is
# reachable) in-cluster kubectl health. Exit 0 = all good, 1 = something's wrong.
# Override: REGION=... CLUSTER=... PROJECT=... EXPECT_NODES=2 EXPECT_SUBNETS=6 ./scripts/verify-exists.sh
set -uo pipefail

REGION="${REGION:-eu-central-1}"
CLUSTER="${CLUSTER:-eks-dev}"
PROJECT="${PROJECT:-eks-dev}"
ECR_REPO="${ECR_REPO:-${PROJECT}/app}"
EXPECT_NODES="${EXPECT_NODES:-2}"
EXPECT_SUBNETS="${EXPECT_SUBNETS:-6}"

fail=0
ok()  { printf '  \033[32m✔\033[0m %-22s %s\n' "$1" "${2:-}"; }
bad() { printf '  \033[31m✗\033[0m %-22s %s\n' "$1" "$2"; fail=1; }

echo "Verifying infra: region=$REGION cluster=$CLUSTER project=$PROJECT"
echo
echo "── AWS resources ──"

st="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query 'cluster.status' --output text 2>/dev/null)"
[ "$st" = "ACTIVE" ] && ok "EKS cluster" "ACTIVE" || bad "EKS cluster" "status=${st:-not found}"

vpc="$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)"
{ [ -n "$vpc" ] && [ "$vpc" != "None" ]; } && ok "VPC" "$vpc" || bad "VPC" "not found"

sn="$(aws ec2 describe-subnets --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" --query 'length(Subnets)' --output text 2>/dev/null)"
[ "${sn:-0}" = "$EXPECT_SUBNETS" ] && ok "Subnets" "$sn" || bad "Subnets" "got ${sn:-0}, want $EXPECT_SUBNETS"

igw="$(aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)"
{ [ -n "$igw" ] && [ "$igw" != "None" ]; } && ok "Internet gateway" "$igw" || bad "Internet gateway" "not found"

nat="$(aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=tag:Project,Values=$PROJECT" --query "NatGateways[?State=='available'].NatGatewayId | [0]" --output text 2>/dev/null)"
{ [ -n "$nat" ] && [ "$nat" != "None" ]; } && ok "NAT gateway" "$nat (available)" || bad "NAT gateway" "none available"

ng="$(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" --query 'nodegroups[0]' --output text 2>/dev/null)"
if [ -n "$ng" ] && [ "$ng" != "None" ]; then
  ngst="$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" --region "$REGION" --query 'nodegroup.status' --output text 2>/dev/null)"
  [ "$ngst" = "ACTIVE" ] && ok "Node group" "$ng (ACTIVE)" || bad "Node group" "$ng status=$ngst"
else
  bad "Node group" "none found"
fi

addons="$(aws eks list-addons --cluster-name "$CLUSTER" --region "$REGION" --query 'addons' --output text 2>/dev/null)"
if [ -n "$addons" ] && [ "$addons" != "None" ]; then
  notactive=""
  for a in $addons; do
    ast="$(aws eks describe-addon --cluster-name "$CLUSTER" --addon-name "$a" --region "$REGION" --query 'addon.status' --output text 2>/dev/null)"
    [ "$ast" = "ACTIVE" ] || notactive="$notactive $a=$ast"
  done
  [ -z "$notactive" ] && ok "Add-ons" "$(echo "$addons" | wc -w | tr -d ' ') ACTIVE" || bad "Add-ons" "not active:$notactive"
else
  bad "Add-ons" "none found"
fi

roles="$(aws iam list-roles --query "length(Roles[?starts_with(RoleName,'${PROJECT}-')])" --output text 2>/dev/null)"
[ "${roles:-0}" -gt 0 ] 2>/dev/null && ok "IAM roles" "$roles found" || bad "IAM roles" "none with prefix ${PROJECT}-"

ecr="$(aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" --query 'repositories[0].repositoryName' --output text 2>/dev/null)"
{ [ -n "$ecr" ] && [ "$ecr" != "None" ]; } && ok "ECR repo" "$ecr" || bad "ECR repo" "$ECR_REPO not found"

echo
echo "── In-cluster (kubectl) ──"
if kubectl get ns >/dev/null 2>&1; then
  ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')"
  total="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "${ready:-0}" -ge "$EXPECT_NODES" ] && ok "Nodes Ready" "$ready/$total" || bad "Nodes Ready" "$ready/$total (want ≥$EXPECT_NODES)"

  notrunning="$(kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"' | wc -l | tr -d ' ')"
  [ "${notrunning:-1}" = "0" ] && ok "kube-system pods" "all Running" || bad "kube-system pods" "$notrunning not Running"

  lbc="$(kubectl get deploy -n kube-system aws-load-balancer-controller -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
  [ "${lbc:-0}" -ge 1 ] 2>/dev/null && ok "LB controller" "$lbc replica(s)" || bad "LB controller" "no available replicas"

  kubectl get storageclass gp3 >/dev/null 2>&1 && ok "gp3 StorageClass" "present" || bad "gp3 StorageClass" "missing (applied manually?)"

  kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 && ok "Gateway API CRDs" "present" || bad "Gateway API CRDs" "missing"
else
  bad "kubectl" "cannot reach cluster — run ./scripts/update-kubeconfig.sh"
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mAll infra present and healthy.\033[0m\n'
else
  printf '\033[31mSome checks failed (above).\033[0m\n'
fi
exit "$fail"
