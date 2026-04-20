output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_arn" {
  value = module.eks.cluster_arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "kubeconfig_command" {
  description = "Run this to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${local.cluster_name}"
}

output "grafana_note" {
  value = "Get Grafana LB: kubectl get svc -n monitoring prometheus-grafana"
}

output "litmus_note" {
  value = "Get Litmus LB: kubectl get svc -n litmus litmus-frontend-service"
}
