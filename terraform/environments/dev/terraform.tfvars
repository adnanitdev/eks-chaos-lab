# terraform/environments/dev/terraform.tfvars
aws_region         = "us-east-1"
cluster_name       = "chaos-lab"
cluster_version    = "1.34"
environment        = "dev"
node_instance_type = "t3.medium"
node_count         = 4
node_min           = 1
node_max           = 5
vpc_cidr           = "10.0.0.0/16"

tags = {
  Project     = "ai-chaos-engineer"
  Environment = "dev"
  ManagedBy   = "terraform"
  Owner       = "devops-team"
}
