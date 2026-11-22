# ecr.tf — Phase 10.1: container registry for app images.

# Renamed 22/11/2026 from "${cluster_name}/app": one repo per app, named after the app. A name change REPLACES the
# repo (ECR can't rename), so the old images went with it; CI re-pushes on the next run.
resource "aws_ecr_repository" "exchange" {
  name = "${var.cluster_name}/exchange"

  # IMMUTABLE (flipped in Phase 12): tag-based CI never re-pushes a version, so lock tags.
  # A tag now maps to exactly one image forever — no silent overwrite, deploys are reproducible.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true # basic vulnerability scan on each push
  }

  force_delete = true # allow `terraform destroy` even if images are present (rebuild-friendly)
}

# The bidders service gets its OWN repo: both CIs tag 0.0.<run_number> from separate counters, so in one
# IMMUTABLE repo the second "0.0.1" push would be rejected. Same settings as `exchange`.
resource "aws_ecr_repository" "bidders" {
  name = "${var.cluster_name}/bidders"

  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  force_delete = true
}

output "exchange_ecr_repository_url" {
  description = "Exchange images: <url>:<tag> (charts/exchange/values.yaml exchange.image.repository)"
  value       = aws_ecr_repository.exchange.repository_url
}

output "bidders_ecr_repository_url" {
  description = "Bidders images: <url>:<tag> (charts/bidders/values.yaml bidders.image.repository)"
  value       = aws_ecr_repository.bidders.repository_url
}
