# vpc.tf — Phase 2: Networking.
# The VPC is the isolated network boundary that every other resource lives inside.

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # Both required by EKS:
  enable_dns_support   = true # Amazon-provided DNS resolver inside the VPC (default true, set for clarity)
  enable_dns_hostnames = true # assign internal DNS hostnames (defaults to false — must enable for EKS)

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

# --- Subnets ---
# One subnet per AZ per tier. CIDRs spelled out explicitly to match the address plan
# (each /20 = ~4,096 addresses, carved from the /16 VPC).
locals {
  public_subnets = {
    "eu-central-1a" = "10.0.0.0/20"
    "eu-central-1b" = "10.0.16.0/20"
    "eu-central-1c" = "10.0.32.0/20"
  }
  private_subnets = {
    "eu-central-1a" = "10.0.48.0/20"
    "eu-central-1b" = "10.0.64.0/20"
    "eu-central-1c" = "10.0.80.0/20"
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = true # public-facing: instances launched here get a public IP

  tags = {
    Name                                        = "${var.cluster_name}-public-${each.key}"
    "kubernetes.io/role/elb"                    = "1"       # LB controller: put internet-facing ALBs here
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"  # cluster discovery (shared, not owned)
  }
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = each.value
  # map_public_ip_on_launch omitted → defaults to false: nodes here never get public IPs

  tags = {
    Name                                        = "${var.cluster_name}-private-${each.key}"
    "kubernetes.io/role/internal-elb"           = "1"       # LB controller: internal LBs here; also where nodes live
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# --- Internet Gateway ---
# The VPC's single door to the internet. Free, HA, one per VPC. Does nothing until a route points at it.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

# --- Public route table ---
# The `local` route (VPC CIDR → local) is implicit and unremovable; we only add the internet route.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0" # everything not local...
    gateway_id = aws_internet_gateway.main.id # ...goes out the internet gateway
  }

  tags = {
    Name = "${var.cluster_name}-public-rt"
  }
}

# Associate the public route table with all three public subnets. Without this they'd fall back
# to the VPC's main route table (local-only) and stay effectively private.
resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public # iterate the public-subnet map, keyed by AZ

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# --- NAT Gateway (single, in AZ-a, for cost) ---
# ⚠️ First billable resource: ~$0.05/hr + data. Prod would run one NAT per AZ for HA;
# we accept a single-AZ dependency + cross-AZ data charges as a conscious learning trade-off.

# Static public IP that becomes the NAT's stable internet identity.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-nat-eip"
  }
}

# The NAT lives in a PUBLIC subnet (so its own egress goes out via the IGW),
# but it serves the PRIVATE subnets.
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["eu-central-1a"].id

  tags = {
    Name = "${var.cluster_name}-nat"
  }

  # The IGW must exist and be attached before the NAT can function.
  # This dependency isn't implied by any attribute reference, so state it explicitly.
  depends_on = [aws_internet_gateway.main]
}

# --- Private route table ---
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id # note: nat_gateway_id, NOT gateway_id
  }

  tags = {
    Name = "${var.cluster_name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
