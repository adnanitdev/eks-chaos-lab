variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "chaos-lab"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.29"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "node_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min" {
  type    = number
  default = 1
}

variable "node_max" {
  type    = number
  default = 4
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default = {
    Project     = "ai-chaos-engineer"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}
