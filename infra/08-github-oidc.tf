# github-oidc.tf — Phase 12.1: let GitHub Actions push to ECR WITHOUT static AWS keys.
#
# Flow: GitHub's IdP signs a short-lived JWT per workflow run (stamped with repo+ref).
# AWS trusts that IdP (the OIDC provider below), and the role's trust policy only lets a
# token assume it if the token's `sub` matches OUR repo on a version tag. Actions then calls
# AssumeRoleWithWebIdentity → ~1h temp creds → push → creds expire. No secret ever stored.

# --- 1. Register GitHub's identity provider in AWS (once per account) ---
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # The audience: who these tokens are FOR. The official value for the AWS creds action.
  client_id_list = ["sts.amazonaws.com"]

  # No thumbprint_list on purpose: AWS no longer verifies the leaf-cert thumbprint for THIS
  # provider (it trusts the public CA behind token.actions.githubusercontent.com). The aws
  # provider (~> 5.0) makes the argument optional as a result — one fewer brittle value to rot.
}

# --- 2. The role Actions assumes ---
# Trust policy = WHO may assume: a GitHub token whose audience is sts.amazonaws.com AND whose
# subject is OUR repo pushing a `v*` TAG or the main branch (main added for learning).
resource "aws_iam_role" "github_actions" {
  name = "${var.cluster_name}-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn } # federated, not a Service
      Action    = "sts:AssumeRoleWithWebIdentity"                            # the web-identity variant
      Condition = {
        # aud MUST equal exactly — pins the token's intended audience.
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # sub uses a wildcard (StringLike) to allow any v* tag but ONLY from our repos: two entries
        # (v* tags, main) per repo in var.github_repos. A list value in a condition = OR.
        # ⚠️ Never loosen the repo part to `*` — that would let ANY GitHub repo assume this role.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = flatten([
            for repo in var.github_repos : [
              "repo:${repo}:ref:refs/tags/v*",
              "repo:${repo}:ref:refs/heads/main",
            ]
          ])
        }
      }
    }]
  })
}

# --- 3. What the role may DO: push to exactly one ECR repo ---
resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "ecr-push"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The docker-login handshake. This action has NO resource-level scoping in AWS —
        # it's an account-wide auth token request — so Resource:"*" is UNAVOIDABLE here.
        # This is the one legitimate `*`; every other statement below is ARN-scoped.
        Sid      = "GetAuthToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        # The actual push (and cache-pull) verbs, scoped to OUR repos' ARNs only.
        # Learning shortcut: one role for both app repos, so the exchange's CI could also push to
        # eks-dev/bidders (and the reverse). Prod would give each GitHub repo its own role + ECR repo.
        Sid    = "PushToAppRepos"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", # does this layer already exist? (dedup)
          "ecr:InitiateLayerUpload",         # begin a layer upload
          "ecr:UploadLayerPart",             # stream layer bytes
          "ecr:CompleteLayerUpload",         # finalize the layer
          "ecr:PutImage",                    # write the manifest = the actual "push"
          "ecr:BatchGetImage",               # read for buildx cache-from
          "ecr:GetDownloadUrlForLayer",      # read layers for cache-from
        ]
        Resource = [aws_ecr_repository.exchange.arn, aws_ecr_repository.bidders.arn]
      },
    ]
  })
}

output "github_actions_role_arn" {
  description = "Set this as the role-to-assume in the GitHub Actions workflow (role ARN, region — no keys)."
  value       = aws_iam_role.github_actions.arn
}
