#!/usr/bin/env bash
# verify-destroyed.sh — read-only check that all Terraform-created infra is gone.
# Strategy: everything got the Project=<name> tag via provider default_tags, so we
# hunt leftovers by tag (EC2 + EKS) and by name prefix (IAM, which is global).
# The S3 state bucket is intentionally NOT checked — it is not managed by Terraform.
set -uo pipefail

REGION="${REGION:-eu-central-1}"
PROJECT="${PROJECT:-eks-dev}"
ECR_REPO="${ECR_REPO:-${PROJECT}/app}"

leftover=0
report() { # $1 label, $2 result (empty => gone)
  if [[ -z "${2// /}" ]]; then
    printf '  \033[32m✔ gone\033[0m    %s\n' "$1"
  else
    printf '  \033[31m✗ EXISTS\033[0m  %s -> %s\n' "$1" "$2"
    leftover=1
  fi
}

echo "Checking region=$REGION  project=$PROJECT"
echo

report "EKS cluster" \
  "$(aws eks list-clusters --region "$REGION" --query "clusters[?@=='$PROJECT']" --output text)"

report "VPC" \
  "$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" --query 'Vpcs[].VpcId' --output text)"

report "Subnets" \
  "$(aws ec2 describe-subnets --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" --query 'Subnets[].SubnetId' --output text)"

report "Internet gateways" \
  "$(aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" --query 'InternetGateways[].InternetGatewayId' --output text)"

# NAT gateways linger in 'deleted' state for up to ~1h after destroy — exclude them.
report "NAT gateways" \
  "$(aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=tag:Project,Values=$PROJECT" --query "NatGateways[?State!='deleted'].NatGatewayId" --output text)"

report "Elastic IPs" \
  "$(aws ec2 describe-addresses --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" --query 'Addresses[].AllocationId' --output text)"

report "Route tables" \
  "$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" --query 'RouteTables[].RouteTableId' --output text)"

report "IAM roles" \
  "$(aws iam list-roles --query "Roles[?starts_with(RoleName, '${PROJECT}-')].RoleName" --output text)"

# ECR repo (node group / add-ons / pod-identity associations vanish WITH the cluster, so the
# EKS-cluster check above covers them; ECR is a standalone resource, so check it explicitly).
report "ECR repo" \
  "$(aws ecr describe-repositories --region "$REGION" --repository-names "$ECR_REPO" --query 'repositories[0].repositoryName' --output text 2>/dev/null)"

# Belt-and-suspenders: anything else in this region still tagged Project=<name>.
# Exclude natgateway ARNs — the tagging API lists NATs in 'deleted' state for ~1h;
# the state-aware itemized check above already covers live ones.
report "Any other tagged resource" \
  "$(aws resourcegroupstaggingapi get-resources --region "$REGION" --tag-filters "Key=Project,Values=$PROJECT" --query "ResourceTagMappingList[?!contains(ResourceARN, ':natgateway/')].ResourceARN" --output text)"

echo
if [[ "$leftover" -eq 0 ]]; then
  printf '\033[32mAll clear — no Terraform-created resources remain.\033[0m\n'
else
  printf '\033[31mSome resources still exist (above). If you just ran destroy, a NAT can\n'
  printf 'linger in "deleted" state briefly — re-run in a few minutes.\033[0m\n'
fi
exit "$leftover"
