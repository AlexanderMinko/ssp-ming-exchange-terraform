#!/usr/bin/env bash
# verify-destroyed.sh — read-only check that the infra/ + platform/ layers are gone, with no orphans.
# Strategy:
#   1. Terraform-created resources: hunted by the Project=<name> tag (provider default_tags) and by name prefix
#      (IAM is global and keyed by name).
#   2. ORPHANS that Terraform never knew about — the most expensive leftovers: ALBs + target groups + security
#      groups the LB controller created for the shared Gateway, and EBS volumes the CSI driver created for PVCs
#      (vmsingle, ClickHouse, ZooKeeper, SigNoz, Mongo). They survive `terraform destroy` if the cluster went
#      first (see pre-destroy.sh).
#   3. A catch-all over the tagging API. WARNING only: that index lags deletions by up to ~1 h, so it can list
#      resources that no longer exist (a "ghost" subnet showed up on 22/11/2026). The itemized checks above are
#      authoritative.
#
# Deliberately NOT checked (they're meant to survive):
#   - the S3 state bucket (not managed by Terraform)
#   - the Secrets Manager secret <project>/exchange/mongodb (out-of-band, reused by the next build)
#   - the load/ layer (EC2 load generator + reports bucket): its own state, built to outlive infra/ destroys.
#     INCLUDE_LOAD=1 checks it too (after `terraform -chdir=load destroy`).
#
# Usage:   ./scripts/verify-destroyed.sh
#          INCLUDE_LOAD=1 ./scripts/verify-destroyed.sh
set -uo pipefail

REGION="${REGION:-eu-central-1}"
PROJECT="${PROJECT:-eks-dev}"
CLUSTER="${CLUSTER:-eks-dev}"
INCLUDE_LOAD="${INCLUDE_LOAD:-0}"
# eks-dev/app is the pre-22/11/2026 name — listed so a stale old repo is caught too.
ECR_REPOS="${ECR_REPOS:-${PROJECT}/exchange ${PROJECT}/bidders ${PROJECT}/app}"
LOAD_ROLE="${PROJECT}-load-generator"

leftover=0
report() { # $1 label, $2 result (empty => gone)
  if [[ -z "${2//[[:space:]]/}" ]]; then
    printf '  \033[32m✔ gone\033[0m    %s\n' "$1"
  else
    printf '  \033[31m✗ EXISTS\033[0m  %s -> %s\n' "$1" "$(echo "$2" | tr '\t\n' '  ')"
    leftover=1
  fi
}
warn() { # $1 label, $2 result (empty => nothing to say)
  if [[ -z "${2//[[:space:]]/}" ]]; then
    printf '  \033[32m✔ none\033[0m    %s\n' "$1"
  else
    printf '  \033[33m? CHECK\033[0m   %s -> %s\n' "$1" "$(echo "$2" | tr '\t\n' '  ')"
  fi
}

echo "Checking region=$REGION project=$PROJECT cluster=$CLUSTER include_load=$INCLUDE_LOAD"

# ── 1. Terraform-created (infra/ + platform/) ─────────────────────────────────────────────────────
echo
echo "── Terraform-created ──"

report "EKS cluster" \
  "$(aws eks list-clusters --region "$REGION" --query "clusters[?@=='$CLUSTER']" --output text)"

report "VPC" \
  "$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" --query 'Vpcs[].VpcId' --output text)"

# The load layer lives in the DEFAULT VPC and creates no subnets/route tables, so the tag alone is safe here.
report "Subnets" \
  "$(aws ec2 describe-subnets --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" --query 'Subnets[].SubnetId' --output text)"

report "Internet gateways" \
  "$(aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" --query 'InternetGateways[].InternetGatewayId' --output text)"

# NAT gateways linger in 'deleted' state for up to ~1 h after destroy — exclude them.
report "NAT gateways" \
  "$(aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=tag:Project,Values=$PROJECT" --query "NatGateways[?State!='deleted'].NatGatewayId" --output text)"

report "Elastic IPs" \
  "$(aws ec2 describe-addresses --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" --query 'Addresses[].AllocationId' --output text)"

report "Route tables" \
  "$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" --query 'RouteTables[].RouteTableId' --output text)"

# infra/: cluster, node, cni, ebs-csi, github-actions; platform/: lbc, eso. The load role is excluded by name.
report "IAM roles" \
  "$(aws iam list-roles --query "Roles[?starts_with(RoleName, '${PROJECT}-') && RoleName!='${LOAD_ROLE}'].RoleName" --output text)"

# platform/01-lb-controller.tf: customer-managed policy <project>-lbc-policy.
report "IAM policies" \
  "$(aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName, '${PROJECT}-')].PolicyName" --output text)"

# infra/08-github-oidc.tf. Global; nothing else in this account should create it.
report "GitHub OIDC provider" \
  "$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?contains(Arn,'token.actions.githubusercontent.com')].Arn" --output text)"

ecr_left=""
for repo in $ECR_REPOS; do
  aws ecr describe-repositories --region "$REGION" --repository-names "$repo" >/dev/null 2>&1 && ecr_left="$ecr_left $repo"
done
report "ECR repos" "$ecr_left"

# ── 2. Orphans (created by in-cluster controllers, unknown to Terraform) ──────────────────────────
echo
echo "── Orphans from in-cluster controllers ──"

# The LB controller tags everything it creates with elbv2.k8s.aws/cluster=<cluster>.
report "ALBs (LB controller)" \
  "$(aws resourcegroupstaggingapi get-resources --region "$REGION" --resource-type-filters elasticloadbalancing:loadbalancer \
      --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTER" --query 'ResourceTagMappingList[].ResourceARN' --output text \
    | tr '\t' '\n' | while read -r arn; do
        [ -n "$arn" ] && aws elbv2 describe-load-balancers --region "$REGION" --load-balancer-arns "$arn" \
          --query 'LoadBalancers[0].LoadBalancerName' --output text 2>/dev/null
      done)"

report "Target groups (LB controller)" \
  "$(aws resourcegroupstaggingapi get-resources --region "$REGION" --resource-type-filters elasticloadbalancing:targetgroup \
      --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTER" --query 'ResourceTagMappingList[].ResourceARN' --output text \
    | tr '\t' '\n' | while read -r arn; do
        [ -n "$arn" ] && aws elbv2 describe-target-groups --region "$REGION" --target-group-arns "$arn" \
          --query 'TargetGroups[0].TargetGroupName' --output text 2>/dev/null
      done)"

report "Security groups (LB controller)" \
  "$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTER" --query 'SecurityGroups[].GroupId' --output text)"

# Volumes the EBS CSI driver created for PVCs carry kubernetes.io/created-for/pvc/name. Any that still exist
# after the cluster is gone are orphans (and are billed per GiB-month).
report "EBS volumes (PVCs)" \
  "$(aws ec2 describe-volumes --region "$REGION" --filters "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
      --query "Volumes[].join(':', [VolumeId, Tags[?Key=='kubernetes.io/created-for/pvc/name'] | [0].Value])" --output text)"

# ── 3. load/ layer (opt-in) ───────────────────────────────────────────────────────────────────────
if [ "$INCLUDE_LOAD" = "1" ]; then
  echo
  echo "── load/ layer ──"
  report "Load generator EC2" \
    "$(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:Component,Values=load-generator" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text)"
  report "Load generator SG" \
    "$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=tag:Component,Values=load-generator" --query 'SecurityGroups[].GroupId' --output text)"
  report "Load generator IAM role" \
    "$(aws iam get-role --role-name "$LOAD_ROLE" --query 'Role.RoleName' --output text 2>/dev/null)"
  report "Reports bucket" \
    "$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '${PROJECT}-load-reports-')].Name" --output text)"
fi

# ── 4. Catch-all (warning only) ───────────────────────────────────────────────────────────────────
echo
echo "── Catch-all: anything else tagged Project=$PROJECT (tagging index lags ~1 h) ──"

# Excluded: NAT gateways (listed for ~1 h in 'deleted' state; the itemized check is state-aware) and, unless
# INCLUDE_LOAD=1, the load layer (Component=load-generator).
if [ "$INCLUDE_LOAD" = "1" ]; then
  q="ResourceTagMappingList[?!contains(ResourceARN, ':natgateway/')].ResourceARN"
else
  q="ResourceTagMappingList[?!contains(ResourceARN, ':natgateway/') && !(Tags[?Key=='Component' && Value=='load-generator'])].ResourceARN"
fi
warn "Other tagged resources" \
  "$(aws resourcegroupstaggingapi get-resources --region "$REGION" --tag-filters "Key=Project,Values=$PROJECT" --query "$q" --output text \
    | tr '\t' '\n' | sed -E 's#^arn:aws:[a-z0-9-]+:[a-z0-9-]*:[0-9]*:##')"

echo
if [[ "$leftover" -eq 0 ]]; then
  printf '\033[32mAll clear — no infra/platform resources or orphans remain.\033[0m\n'
  printf 'A "? CHECK" line above with all-green itemized checks is usually a lagging tagging index — re-run in an hour.\n'
else
  printf '\033[31mSome resources still exist (above).\033[0m\n'
  printf 'Orphan ALBs/volumes: the cluster was destroyed before its controllers could clean up — delete them in the console\n'
  printf 'and run ./scripts/pre-destroy.sh before the next destroy. A NAT can linger briefly — re-run in a few minutes.\n'
fi
exit "$leftover"
