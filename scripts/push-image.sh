#!/usr/bin/env bash
# push-image.sh — build a Docker image and push it to the project's ECR repo.
# The repo URI is looked up from AWS (aws ecr describe-repositories), not hardcoded —
# so the account id / registry host are never baked into the script.
#
# Usage:  ./scripts/push-image.sh [TAG] [BUILD_CONTEXT]
#   TAG            image tag           (default: v1)
#   BUILD_CONTEXT  docker build context (default: current dir)
# Override defaults with env: REGION=... REPO_NAME=... ./scripts/push-image.sh
set -euo pipefail

REGION="${REGION:-eu-central-1}"
REPO_NAME="${REPO_NAME:-eks-dev/app}"
TAG="${1:-v1}"
CONTEXT="${2:-.}"

# Discover the full repo URI (registry host + name) from AWS.
REPO_URI="$(aws ecr describe-repositories \
  --repository-names "$REPO_NAME" --region "$REGION" \
  --query 'repositories[0].repositoryUri' --output text)"
REGISTRY="${REPO_URI%%/*}" # strip everything after the first slash → the registry host

echo "repo:     $REPO_NAME"
echo "image:    $REPO_URI:$TAG"

# Authenticate docker to ECR (temporary token, piped — never printed).
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

# Build + push.
docker build -t "$REPO_URI:$TAG" "$CONTEXT"
docker push "$REPO_URI:$TAG"

echo "pushed $REPO_URI:$TAG"
