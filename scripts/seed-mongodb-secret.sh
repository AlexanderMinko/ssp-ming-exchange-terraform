#!/usr/bin/env bash
# seed-mongodb-secret.sh — make sure the MongoDB credentials exist in Secrets Manager.
#
# WHY this is a script and not Terraform: TF state is plaintext in S3, so the secret VALUE
# must never enter Terraform. platform/03-eso.tf only REFERENCES this secret (data source, by
# ARN) to scope the ESO IAM policy. So: this script creates the value out-of-band; Terraform
# reads it. Run this BEFORE `terraform apply` in platform/ (the data lookup fails without it).
#
# Behaviour (changed 22/11/2026 — it used to rotate on EVERY run, which locked the apps out):
#   absent                  → create with a fresh random password
#   scheduled for deletion  → restore it (keeps the existing value)
#   exists                  → do NOTHING (safe to run any time, e.g. before every platform apply)
#   ROTATE=1                → new random password, but ONLY if no Mongo data volume exists in the cluster
#
# Why rotation is guarded: mongo:7 creates its root user from MONGO_INITDB_ROOT_* ONCE, on an empty data
# directory, and ignores those variables forever after. Rotating the secret while data-mongodb-0 exists changes
# what ESO hands the apps, NOT the password inside Mongo → every pod that restarts gets AuthenticationFailed
# (happened 22/11/2026). A real rotation with live data needs `db.changeUserPassword` inside Mongo first.
#
# Usage:    ./scripts/seed-mongodb-secret.sh
#           ROTATE=1 ./scripts/seed-mongodb-secret.sh     (cluster destroyed, or Mongo PVC deleted)
# Override: CLUSTER=... REGION=... MONGO_USER=... NAMESPACE=... ./scripts/seed-mongodb-secret.sh
set -euo pipefail

REGION="${REGION:-eu-central-1}"
CLUSTER="${CLUSTER:-eks-dev}"
MONGO_USER="${MONGO_USER:-exchange}"
SECRET_NAME="${SECRET_NAME:-${CLUSTER}/exchange/mongodb}"
NAMESPACE="${NAMESPACE:-production}"
MONGO_PVC="${MONGO_PVC:-data-mongodb-0}" # volumeClaimTemplate `data` of StatefulSet `mongodb`
ROTATE="${ROTATE:-0}"

command -v jq >/dev/null || { echo "ERROR: jq is required (brew install jq)." >&2; exit 1; }

new_secret_json() {
  # Generate the password SERVER-SIDE (never touches disk or the terminal). Punctuation excluded
  # to avoid escaping/URL-encoding pain in Mongo connection strings.
  local password
  password="$(aws secretsmanager get-random-password \
    --region "$REGION" \
    --password-length 32 \
    --exclude-punctuation \
    --require-each-included-type \
    --query RandomPassword --output text)"
  # Build the JSON with jq so any special chars are escaped correctly. Keys MUST match the
  # mongo:7 init env vars (MONGO_INITDB_ROOT_*) — that's what the ExternalSecrets map from.
  jq -nc --arg u "$MONGO_USER" --arg p "$password" \
    '{MONGO_INITDB_ROOT_USERNAME:$u, MONGO_INITDB_ROOT_PASSWORD:$p}'
}

# Returns 0 if the cluster is reachable AND Mongo's data volume exists (= a user is already initialised).
mongo_data_exists() {
  aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1 || return 1
  local ctx
  ctx="$(kubectl config get-contexts -o name 2>/dev/null | grep -E "arn:aws:eks:${REGION}:[0-9]+:cluster/${CLUSTER}$" | head -1)"
  if [[ -z "$ctx" ]] || ! kubectl --context "$ctx" get ns >/dev/null 2>&1; then
    # Cluster exists but we can't look inside → can't prove it's safe. Treat as "data exists".
    echo "WARNING: cluster $CLUSTER exists but kubectl can't reach it (run ./scripts/update-kubeconfig.sh)." >&2
    return 0
  fi
  kubectl --context "$ctx" -n "$NAMESPACE" get pvc "$MONGO_PVC" >/dev/null 2>&1
}

# Describe returns non-zero if the secret truly doesn't exist; capture state to branch on it.
state="$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" \
  --query '{deleted: DeletedDate}' --output text 2>/dev/null || echo "ABSENT")"

if [[ "$state" == "ABSENT" ]]; then
  echo "Secret '$SECRET_NAME' absent → creating."
  aws secretsmanager create-secret \
    --name "$SECRET_NAME" --region "$REGION" \
    --secret-string "$(new_secret_json)" >/dev/null
  echo "Done: $SECRET_NAME created for user '$MONGO_USER'. (Password not printed — it lives only in Secrets Manager.)"
  exit 0
fi

# If it was scheduled for deletion (has a DeletedDate), restore it — the old value comes back with it.
if [[ "$state" != "None" ]]; then
  echo "Secret '$SECRET_NAME' was scheduled for deletion → restoring (existing value kept)."
  aws secretsmanager restore-secret --secret-id "$SECRET_NAME" --region "$REGION" >/dev/null
fi

if [[ "$ROTATE" != "1" ]]; then
  echo "Secret '$SECRET_NAME' exists → left unchanged. (ROTATE=1 to generate a new password.)"
  exit 0
fi

if mongo_data_exists; then
  cat >&2 <<EOF
REFUSED: Mongo's data volume ($NAMESPACE/$MONGO_PVC) exists, so its root user already has the CURRENT password.
Rotating only the secret would lock out every app pod on its next restart.

Either start from empty data (destroys the synthetic seed data; the apps re-seed at startup):
  kubectl -n $NAMESPACE delete statefulset mongodb && kubectl -n $NAMESPACE delete pvc $MONGO_PVC
  ROTATE=1 ./scripts/seed-mongodb-secret.sh      (then let Argo CD recreate the StatefulSet)
or rotate for real: db.changeUserPassword('$MONGO_USER', '<new>') inside Mongo first, then
  put the same value into $SECRET_NAME and force the ExternalSecrets to sync.
EOF
  exit 1
fi

echo "Secret '$SECRET_NAME' exists, no Mongo data volume → rotating (new version)."
aws secretsmanager put-secret-value \
  --secret-id "$SECRET_NAME" --region "$REGION" \
  --secret-string "$(new_secret_json)" >/dev/null
echo "Done: $SECRET_NAME rotated for user '$MONGO_USER'. (Password not printed — it lives only in Secrets Manager.)"
