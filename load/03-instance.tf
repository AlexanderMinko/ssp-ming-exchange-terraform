# instance.tf — the load generator itself.

# Latest Amazon Linux 2023 AMI, published by AWS as a public SSM parameter. No hardcoded AMI id
# to go stale. AL2023 ships SSM Agent preinstalled and has Corretto (OpenJDK) in its repos.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.ami_architecture}"
}

resource "aws_instance" "load" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.load.id]
  iam_instance_profile   = aws_iam_instance_profile.load.name

  # Runs once, as root, on first boot. Progress: /var/log/cloud-init-output.log on the instance.
  user_data                   = file("${path.module}/user-data.sh")
  user_data_replace_on_change = true # edit the script → Terraform replaces the instance

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gib
    encrypted   = true
  }

  # IMDSv2 only (token-based metadata): blocks the classic SSRF credential-theft path.
  metadata_options {
    http_tokens = "required"
  }

  # A new AMI version would otherwise show up as a diff on every plan and replace the box.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name = "${var.project}-load-generator"
  }
}

output "instance_id" {
  description = "For: aws ssm start-session --target <id>"
  value       = aws_instance.load.id
}

output "connect" {
  value = "aws ssm start-session --region ${var.region} --target ${aws_instance.load.id}"
}
