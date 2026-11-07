#!/usr/bin/env bash
# seed-mongodb-secret.sh — generate fresh MongoDB creds and store them in Secrets Manager.
#
# WHY this is a script and not Terraform: TF state is plaintext in S3, so the secret VALUE
# must never enter Terraform. platform/03-eso.tf only REFERENCES this secret (data source, by
# ARN) to scope the ESO IAM policy. So: this script creates the value out-of-band; Terraform
# reads it. Run this BEFORE `terraform apply` in platform/ (the data lookup fails without it).
#
# Idempotent: creates the secret if absent, otherwise ROTATES it (new random password).
# Safe to rotate because Mongo's volume is reclaimPolicy=Delete → fresh empty DB each rebuild,
# so new creds always match a freshly-initialized DB. (Would NOT be safe on a persistent volume.)
#
# Override defaults with env vars: CLUSTER=... REGION=... MONGO_USER=... ./scripts/seed-mongodb-secret.sh
set -euo pipefail

REGION="${REGION:-eu-central-1}"
CLUSTER="${CLUSTER:-eks-dev}"
MONGO_USER="${MONGO_USER:-exchange}"
SECRET_NAME="${SECRET_NAME:-${CLUSTER}/exchange/mongodb}"

command -v jq >/dev/null || { echo "ERROR: jq is required (brew install jq)." >&2; exit 1; }

# Generate the password SERVER-SIDE (never touches disk or the terminal). Punctuation excluded
# to avoid escaping/URL-encoding pain in Mongo connection strings.
PASSWORD="$(aws secretsmanager get-random-password \
  --region "$REGION" \
  --password-length 32 \
  --exclude-punctuation \
  --require-each-included-type \
  --query RandomPassword --output text)"

# Build the JSON with jq so any special chars are escaped correctly. Keys MUST match the
# mongo:7 init env vars (MONGO_INITDB_ROOT_*) — that's what the ExternalSecret maps from.
SECRET_JSON="$(jq -nc --arg u "$MONGO_USER" --arg p "$PASSWORD" \
  '{MONGO_INITDB_ROOT_USERNAME:$u, MONGO_INITDB_ROOT_PASSWORD:$p}')"

# Describe returns non-zero if the secret truly doesn't exist; capture state to branch on it.
state="$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" \
  --query '{deleted: DeletedDate}' --output text 2>/dev/null || echo "ABSENT")"

if [[ "$state" == "ABSENT" ]]; then
  echo "Secret '$SECRET_NAME' absent → creating."
  aws secretsmanager create-secret \
    --name "$SECRET_NAME" --region "$REGION" \
    --secret-string "$SECRET_JSON" >/dev/null
else
  # If it was scheduled for deletion (has a DeletedDate), restore it before writing.
  if [[ "$state" != "None" ]]; then
    echo "Secret '$SECRET_NAME' was scheduled for deletion → restoring."
    aws secretsmanager restore-secret --secret-id "$SECRET_NAME" --region "$REGION" >/dev/null
  fi
  echo "Secret '$SECRET_NAME' exists → rotating (new version)."
  aws secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME" --region "$REGION" \
    --secret-string "$SECRET_JSON" >/dev/null
fi

echo "Done: $SECRET_NAME set for user '$MONGO_USER'. (Password not printed — it lives only in Secrets Manager.)"
