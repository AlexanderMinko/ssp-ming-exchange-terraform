#!/usr/bin/env bash
# verify-exists.sh — read-only check that the infra (and, by default, the platform + apps) is CREATED and HEALTHY.
# Inverse of verify-destroyed.sh. Sections:
#   1. AWS — infra layer      (infra/: VPC, EKS, nodes, add-ons, IAM, OIDC, ECR) + the out-of-band Mongo secret
#   2. AWS — platform layer   (platform/: LBC + ESO IAM, Pod Identity associations, the shared ALB)
#   3. In-cluster             (nodes, controllers, Gateway, ESO, Argo CD apps, VictoriaMetrics, SigNoz, app pods, PVCs)
# Exit 0 = all good, 1 = something's wrong. Never changes anything.
#
# kubectl runs against the eks-dev context EXPLICITLY (found by the cluster ARN), never the current context,
# so a kubeconfig pointing at another cluster can't produce false greens.
#
# Usage:   ./scripts/verify-exists.sh                 (everything)
#          SCOPE=infra ./scripts/verify-exists.sh     (only infra/ — e.g. before the platform apply)
# Override: REGION=... CLUSTER=... PROJECT=... EXPECT_NODES=3 EXPECT_SUBNETS=6
set -uo pipefail

REGION="${REGION:-eu-central-1}"
CLUSTER="${CLUSTER:-eks-dev}"
PROJECT="${PROJECT:-eks-dev}"
SCOPE="${SCOPE:-all}" # infra | all
EXPECT_NODES="${EXPECT_NODES:-3}"
EXPECT_SUBNETS="${EXPECT_SUBNETS:-6}"
ECR_REPOS="${ECR_REPOS:-${PROJECT}/exchange ${PROJECT}/bidders}"
INFRA_ROLES="cluster-role node-role cni-role ebs-csi-role github-actions-role"
PLATFORM_ROLES="lbc-role eso-role"
EXPECT_ADDONS="eks-pod-identity-agent vpc-cni kube-proxy coredns metrics-server aws-ebs-csi-driver"
MONGO_SECRET="${MONGO_SECRET:-${PROJECT}/exchange/mongodb}"

fail=0
ok()   { printf '  \033[32m✔\033[0m %-26s %s\n' "$1" "${2:-}"; }
bad()  { printf '  \033[31m✗\033[0m %-26s %s\n' "$1" "$2"; fail=1; }
info() { printf '  \033[33m•\033[0m %-26s %s\n' "$1" "$2"; }
found() { [ -n "$1" ] && [ "$1" != "None" ]; }

echo "Verifying: region=$REGION cluster=$CLUSTER project=$PROJECT scope=$SCOPE"

# ── 1. AWS — infra layer ──────────────────────────────────────────────────────────────────────────
echo
echo "── AWS — infra layer ──"

st="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query 'cluster.status' --output text 2>/dev/null)"
[ "$st" = "ACTIVE" ] && ok "EKS cluster" "ACTIVE" || bad "EKS cluster" "status=${st:-not found}"

vpc="$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)"
found "$vpc" && ok "VPC" "$vpc" || bad "VPC" "not found"

if found "$vpc"; then
  # Filter by the VPC, not just the tag: the load layer's resources carry the same Project tag.
  sn="$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$vpc" "Name=tag:Project,Values=$PROJECT" --query 'length(Subnets)' --output text 2>/dev/null)"
  [ "${sn:-0}" = "$EXPECT_SUBNETS" ] && ok "Subnets" "$sn" || bad "Subnets" "got ${sn:-0}, want $EXPECT_SUBNETS"
fi

igw="$(aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)"
found "$igw" && ok "Internet gateway" "$igw" || bad "Internet gateway" "not found"

nat="$(aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=tag:Project,Values=$PROJECT" --query "NatGateways[?State=='available'].NatGatewayId | [0]" --output text 2>/dev/null)"
found "$nat" && ok "NAT gateway" "$nat (available)" || bad "NAT gateway" "none available"

ng="$(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" --query 'nodegroups[0]' --output text 2>/dev/null)"
if found "$ng"; then
  read -r ngst ngtype ngdesired <<<"$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" --region "$REGION" \
    --query 'nodegroup.[status,instanceTypes[0],scalingConfig.desiredSize]' --output text 2>/dev/null)"
  [ "$ngst" = "ACTIVE" ] && ok "Node group" "$ng ($ngst, ${ngdesired} × ${ngtype})" || bad "Node group" "$ng status=$ngst"
else
  bad "Node group" "none found"
fi

# --output text separates list items with TABS; normalise to spaces so the " $a " match below works.
addons="$(aws eks list-addons --cluster-name "$CLUSTER" --region "$REGION" --query 'addons' --output text 2>/dev/null | tr '\t' ' ')"
missing=""; notactive=""
for a in $EXPECT_ADDONS; do
  case " $addons " in
    *" $a "*)
      ast="$(aws eks describe-addon --cluster-name "$CLUSTER" --addon-name "$a" --region "$REGION" --query 'addon.status' --output text 2>/dev/null)"
      [ "$ast" = "ACTIVE" ] || notactive="$notactive $a=$ast" ;;
    *) missing="$missing $a" ;;
  esac
done
if [ -z "$missing$notactive" ]; then
  ok "Add-ons" "$(echo "$EXPECT_ADDONS" | wc -w | tr -d ' ') ACTIVE"
else
  bad "Add-ons" "${missing:+missing:$missing }${notactive:+not active:$notactive}"
fi

check_roles() { # $1 label, $2 role suffixes
  local missing_roles="" role
  for role in $2; do
    aws iam get-role --role-name "${PROJECT}-${role}" >/dev/null 2>&1 || missing_roles="$missing_roles ${PROJECT}-${role}"
  done
  [ -z "$missing_roles" ] && ok "$1" "$(echo "$2" | wc -w | tr -d ' ') present" || bad "$1" "missing:$missing_roles"
}
check_roles "IAM roles (infra)" "$INFRA_ROLES"

oidc="$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?contains(Arn,'token.actions.githubusercontent.com')].Arn | [0]" --output text 2>/dev/null)"
found "$oidc" && ok "GitHub OIDC provider" "present" || bad "GitHub OIDC provider" "missing — CI can't assume its role"

for repo in $ECR_REPOS; do
  # Tagged images only: buildx also pushes untagged attestation manifests, which would inflate the count.
  images="$(aws ecr describe-images --repository-name "$repo" --region "$REGION" --query 'length(imageDetails[?imageTags])' --output text 2>/dev/null)"
  if [ -z "$images" ]; then
    bad "ECR $repo" "not found"
  elif [ "$images" = "0" ]; then
    info "ECR $repo" "exists, EMPTY — re-run that app's CI before Argo CD can pull"
  else
    latest="$(aws ecr describe-images --repository-name "$repo" --region "$REGION" \
      --query 'sort_by(imageDetails[?imageTags],&imagePushedAt)[-1].imageTags[0]' --output text 2>/dev/null)"
    ok "ECR $repo" "$images image(s), latest $latest"
  fi
done

# Out-of-band (never in Terraform): ESO syncs it into the Mongo/app Secrets. Metadata only, never the value.
sec="$(aws secretsmanager describe-secret --secret-id "$MONGO_SECRET" --region "$REGION" --query 'Name' --output text 2>/dev/null)"
found "$sec" && ok "Secret (out-of-band)" "$MONGO_SECRET" || bad "Secret (out-of-band)" "$MONGO_SECRET missing — run ./scripts/seed-mongodb-secret.sh"

if [ "$SCOPE" = "infra" ]; then
  echo
  [ "$fail" -eq 0 ] && printf '\033[32mInfra layer present and healthy.\033[0m\n' || printf '\033[31mSome infra checks failed (above).\033[0m\n'
  exit "$fail"
fi

# ── 2. AWS — platform layer ───────────────────────────────────────────────────────────────────────
echo
echo "── AWS — platform layer ──"

check_roles "IAM roles (platform)" "$PLATFORM_ROLES"

pia="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --region "$REGION" \
  --query 'associations[].serviceAccount' --output text 2>/dev/null | tr '\t' '\n')"
missing=""
for sa in aws-node ebs-csi-controller-sa aws-load-balancer-controller external-secrets; do
  echo "$pia" | grep -qx "$sa" || missing="$missing $sa"
done
[ -z "$missing" ] && ok "Pod Identity associations" "4 present" || bad "Pod Identity associations" "missing:$missing"

# The shared Gateway's ALB is created by the LB controller, not Terraform → find it by the controller's tag.
alb="$(aws resourcegroupstaggingapi get-resources --region "$REGION" --resource-type-filters elasticloadbalancing:loadbalancer \
  --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTER" --query 'ResourceTagMappingList[0].ResourceARN' --output text 2>/dev/null)"
if found "$alb"; then
  read -r albst albdns <<<"$(aws elbv2 describe-load-balancers --load-balancer-arns "$alb" --region "$REGION" \
    --query 'LoadBalancers[0].[State.Code,DNSName]' --output text 2>/dev/null)"
  [ "$albst" = "active" ] && ok "Shared ALB" "$albdns" || bad "Shared ALB" "state=${albst:-unknown}"
else
  bad "Shared ALB" "none tagged elbv2.k8s.aws/cluster=$CLUSTER (Gateway edge/shared not programmed?)"
fi

# ── 3. In-cluster ─────────────────────────────────────────────────────────────────────────────────
echo
echo "── In-cluster (kubectl) ──"

CTX="$(kubectl config get-contexts -o name 2>/dev/null | grep -E "arn:aws:eks:${REGION}:[0-9]+:cluster/${CLUSTER}$" | head -1)"
if [ -z "$CTX" ]; then
  bad "kubeconfig" "no context for cluster/$CLUSTER — run ./scripts/update-kubeconfig.sh"
elif ! kubectl --context "$CTX" get ns >/dev/null 2>&1; then
  # Usual cause after a destroy + rebuild: the context still holds the OLD cluster's endpoint and CA.
  bad "kubectl" "context $CTX unreachable — stale after a rebuild? run ./scripts/update-kubeconfig.sh"
else
  k() { kubectl --context "$CTX" "$@"; }

  ready="$(k get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')"
  total="$(k get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "${ready:-0}" -ge "$EXPECT_NODES" ] && ok "Nodes Ready" "$ready/$total" || bad "Nodes Ready" "$ready/$total (want ≥$EXPECT_NODES)"

  # Pods not Running/Completed, or Running but with a container not ready (e.g. 0/1).
  pods_unhealthy() { # $1 namespace
    k get pods -n "$1" --no-headers 2>/dev/null | awk '
      $3=="Completed" { next }
      $3!="Running"   { bad++; next }
      { split($2, r, "/"); if (r[1] != r[2]) bad++ }
      END { print bad+0 }'
  }
  for ns in kube-system external-secrets argocd monitoring signoz production; do
    if ! k get ns "$ns" >/dev/null 2>&1; then
      bad "pods $ns" "namespace missing"
      continue
    fi
    n="$(k get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    u="$(pods_unhealthy "$ns")"
    if [ "$n" = "0" ]; then
      bad "pods $ns" "no pods"
    elif [ "$u" = "0" ]; then
      ok "pods $ns" "$n Running and Ready"
    else
      bad "pods $ns" "$u of $n not Ready — kubectl get pods -n $ns"
    fi
  done

  lbc="$(k get deploy -n kube-system aws-load-balancer-controller -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
  [ "${lbc:-0}" -ge 1 ] 2>/dev/null && ok "LB controller" "$lbc replica(s)" || bad "LB controller" "no available replicas"

  k get storageclass gp3 >/dev/null 2>&1 && ok "gp3 StorageClass" "present" || bad "gp3 StorageClass" "missing"

  missing=""
  for crd in gateways.gateway.networking.k8s.io servicemonitors.monitoring.coreos.com vmservicescrapes.operator.victoriametrics.com; do
    k get crd "$crd" >/dev/null 2>&1 || missing="$missing $crd"
  done
  [ -z "$missing" ] && ok "CRDs" "Gateway API, ServiceMonitor, VM" || bad "CRDs" "missing:$missing"

  gw="$(k get gateway shared -n edge -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)"
  [ "$gw" = "True" ] && ok "Gateway edge/shared" "Programmed" || bad "Gateway edge/shared" "Programmed=${gw:-not found}"

  css="$(k get clustersecretstore aws-secretsmanager -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  [ "$css" = "True" ] && ok "ClusterSecretStore" "Ready (Pod Identity auth works)" || bad "ClusterSecretStore" "Ready=${css:-not found}"

  # Every Argo CD Application must be Synced + Healthy (root, exchange, bidders, mongodb, grafana-dashboards).
  apps="$(k get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' 2>/dev/null)"
  if [ -z "$apps" ]; then
    bad "Argo CD apps" "none — root app not applied?"
  else
    while read -r name sync health; do
      [ -z "$name" ] && continue
      { [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; } \
        && ok "Argo app $name" "Synced, Healthy" \
        || bad "Argo app $name" "sync=${sync:-?} health=${health:-?}"
    done <<<"$apps"
  fi

  ds="$(k get ds -n signoz -l app.kubernetes.io/component=otel-agent -o jsonpath='{.items[0].status.numberReady}/{.items[0].status.desiredNumberScheduled}' 2>/dev/null)"
  { [ -n "$ds" ] && [ "${ds%/*}" = "${ds#*/}" ] && [ "${ds%/*}" != "0" ]; } \
    && ok "SigNoz log agent" "$ds nodes" || bad "SigNoz log agent" "ready/desired=${ds:-not found}"

  pending="$(k get pvc -A --no-headers 2>/dev/null | awk '$3!="Bound"' | wc -l | tr -d ' ')"
  pvcs="$(k get pvc -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "$pending" = "0" ] && ok "PVCs" "$pvcs Bound" || bad "PVCs" "$pending of $pvcs not Bound — kubectl get pvc -A"
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mAll infra, platform and apps present and healthy.\033[0m\n'
else
  printf '\033[31mSome checks failed (above).\033[0m\n'
fi
exit "$fail"
