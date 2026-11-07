# ecr.tf — Phase 10.1: container registry for app images.

resource "aws_ecr_repository" "app" {
  name = "${var.cluster_name}/app" //TODO: ssp-exchange

  # IMMUTABLE (flipped in Phase 12): tag-based CI never re-pushes a version, so lock tags.
  # A tag now maps to exactly one image forever — no silent overwrite, deploys are reproducible.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true # basic vulnerability scan on each push
  }

  force_delete = true # allow `terraform destroy` even if images are present (rebuild-friendly)
}

output "ecr_repository_url" {
  description = "Push images here: <url>:<tag>"
  value       = aws_ecr_repository.app.repository_url
}
