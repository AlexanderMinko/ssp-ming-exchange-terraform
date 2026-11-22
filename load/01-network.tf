# network.tf — where the instance lives and what may reach it.
# Default VPC on purpose: publishers sit outside the cluster's VPC, and this layer must not
# depend on infra/ (the cluster is destroyed often; the load generator may outlive it).

data "aws_vpc" "default" {
  default = true
}

# Any public subnet of the default VPC (every default subnet maps a public IP on launch).
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

resource "aws_security_group" "load" {
  name        = "${var.project}-load-generator"
  description = "Gatling load generator: egress only, access via SSM Session Manager"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${var.project}-load-generator"
  }
}

# Egress: everything. Needed for the ALB (80), SSM endpoints (443), dnf/sbt/Maven downloads (443).
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.load.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# No ingress rules at all: SSM Session Manager needs no inbound port.
