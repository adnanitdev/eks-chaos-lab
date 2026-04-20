variable "name"         { type = string }
variable "vpc_cidr"     { type = string }
variable "azs"          { type = list(string) }
variable "cluster_name" { type = string }
variable "tags"         { type = map(string) }

locals {
  # Carve /24 subnets from the /16 CIDR
  public_cidrs  = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  private_cidrs = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 8, i + 10)]
}

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name                                        = var.name
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-igw" })
}

# ── Public Subnets ────────────────────────────────────────────────────────────

resource "aws_subnet" "public" {
  count                   = length(var.azs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name                                        = "${var.name}-public-${var.azs[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-public-rt" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── NAT Gateways (one per AZ for HA) ─────────────────────────────────────────

resource "aws_eip" "nat" {
  count  = length(var.azs)
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat-eip-${count.index}" })
}

resource "aws_nat_gateway" "this" {
  count         = length(var.azs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(var.tags, { Name = "${var.name}-nat-${count.index}" })
  depends_on    = [aws_internet_gateway.this]
}

# ── Private Subnets ───────────────────────────────────────────────────────────

resource "aws_subnet" "private" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(var.tags, {
    Name                                        = "${var.name}-private-${var.azs[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "kubernetes.io/role/internal-elb"           = "1"
  })
}

resource "aws_route_table" "private" {
  count  = length(var.azs)
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-private-rt-${count.index}" })
}

resource "aws_route" "private_nat" {
  count                  = length(var.azs)
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "vpc_id"             { value = aws_vpc.this.id }
output "public_subnet_ids"  { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
