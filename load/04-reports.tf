# reports.tf — S3 bucket for Gatling reports, so they can be read from the laptop after a run.
# Lives and dies with this layer: `terraform destroy` empties and deletes it (force_destroy = true).
# Download any report you want to keep BEFORE destroying.

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "reports" {
  # Bucket names are global across all AWS accounts → the account id makes it unique.
  bucket = "${var.project}-load-reports-${data.aws_caller_identity.current.account_id}"

  # Without this, destroy fails with BucketNotEmpty. With it, Terraform deletes every object first.
  force_destroy = true
}

# Private: no ACLs, no public policies, ever. Reports are read with your AWS credentials.
resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The instance may write and list under reports/ in THIS bucket only — not read other buckets,
# not delete. `aws s3 sync` needs ListBucket to compare what is already uploaded.
data "aws_iam_policy_document" "reports_write" {
  statement {
    sid       = "ListReports"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.reports.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["reports/*"]
    }
  }
  statement {
    sid       = "UploadReports"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.reports.arn}/reports/*"]
  }
}

resource "aws_iam_role_policy" "reports_write" {
  name   = "write-load-reports"
  role   = aws_iam_role.load.id
  policy = data.aws_iam_policy_document.reports_write.json
}

output "reports_bucket" {
  value = aws_s3_bucket.reports.bucket
}
