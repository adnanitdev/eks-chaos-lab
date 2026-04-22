locals {
  cluster_name = "${var.cluster_name}-${var.environment}"
  azs          = slice(data.aws_availability_zones.available.names, 0, 3)
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# ── VPC ───────────────────────────────────────────────────────────────────────

module "vpc" {
  source = "./modules/vpc"

  name         = local.cluster_name
  vpc_cidr     = var.vpc_cidr
  azs          = local.azs
  cluster_name = local.cluster_name
  tags         = var.tags
}

# ── EKS ───────────────────────────────────────────────────────────────────────

module "eks" {
  source = "./modules/eks"

  cluster_name       = local.cluster_name
  cluster_version    = var.cluster_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids
  node_instance_type = var.node_instance_type
  node_count         = var.node_count
  node_min           = var.node_min
  node_max           = var.node_max
  aws_region         = var.aws_region
  account_id         = data.aws_caller_identity.current.account_id
  tags               = var.tags
}

# ── Prometheus + Grafana (kube-prometheus-stack) ──────────────────────────────

resource "helm_release" "prometheus_stack" {
  name             = "prometheus"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "58.2.2"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 600

  values = [
    yamlencode({
      prometheus = {
        prometheusSpec = {
          retention              = "7d"
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                accessModes = ["ReadWriteOnce"]
                resources   = { requests = { storage = "10Gi" } }
              }
            }
          }
        }
      }
      grafana = {
        enabled        = true
        adminPassword  = "chaos-lab-admin"
        service        = { type = "LoadBalancer" }
        persistence    = { enabled = true, size = "2Gi" }
      }
      alertmanager = { enabled = false }
    })
  ]

  depends_on = [module.eks, helm_release.aws_lb_controller]
}

# ── Metrics Server (deploy early — HPA depends on it) ────────────────────────

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.12.1"
  namespace  = "kube-system"

  depends_on = [module.eks]
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner = "ebs.csi.aws.com"

  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type = "gp3"
  }

  allow_volume_expansion = true
}
# ── AWS Load Balancer Controller ──────────────────────────────────────────────
# Must be fully Ready before any helm release creates a LoadBalancer Service,
# otherwise the mutating webhook is unavailable and Chaos Mesh / Litmus fail.

resource "helm_release" "aws_lb_controller" {
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  namespace        = "kube-system"
  timeout          = 300

  # Wait until the controller deployment is fully available before continuing
  wait          = true
  wait_for_jobs = true

  set {
    name  = "clusterName"
    value = local.cluster_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks.lb_controller_role_arn
  }
  # Ensure the webhook is healthy before marking release complete
  set {
    name  = "webhookTLS.auto"
    value = "true"
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  depends_on = [module.eks, helm_release.metrics_server]
}

# ── LitmusChaos ───────────────────────────────────────────────────────────────
# Chart was renamed: the correct chart is "litmus-2-0-0" in the litmuschaos repo.
# Latest stable: 3.8.0 as of 2024-Q4.

resource "helm_release" "litmus" {
  name             = "litmus"
  repository       = "https://litmuschaos.github.io/litmus-helm/"
  chart            = "litmus"
  version          = "3.28.0"
  namespace        = "litmus"
  create_namespace = true
  timeout          = 300
  wait             = true

  set {
    name  = "portal.frontend.service.type"
    value = "ClusterIP"   # avoid LB dependency; access via kubectl port-forward
  }

  depends_on = [module.eks, helm_release.aws_lb_controller]
}

# ── Chaos Mesh ────────────────────────────────────────────────────────────────
# Pin to 2.7.0 (2.6.3 had webhook CRD issues on EKS 1.29).
# Use ClusterIP for dashboard — avoids the LB webhook race condition.

resource "helm_release" "chaos_mesh" {
  name             = "chaos-mesh"
  repository       = "https://charts.chaos-mesh.org"
  chart            = "chaos-mesh"
  namespace        = "chaos-mesh"
  create_namespace = true
  timeout          = 300
  wait             = true

  set {
    name  = "dashboard.service.type"
    value = "ClusterIP"   # access via: kubectl port-forward svc/chaos-dashboard 2333:2333 -n chaos-mesh
  }
  # Ensure CRDs are installed before controller starts
  set {
    name  = "controllerManager.enableFilterNamespace"
    value = "false"
  }

  depends_on = [module.eks, helm_release.aws_lb_controller]
}

# ── Prometheus + Grafana (kube-prometheus-stack) ──────────────────────────────
# Deploy after LB controller so Grafana's LoadBalancer service provisions cleanly.
