locals {
  name        = local.environment
  environment = "control-plane"
  location    = var.location


  #cluster_version = var.kubernetes_version

  gitops_addons_url      = "${var.gitops_addons_org}/${var.gitops_addons_repo}"
  gitops_addons_basepath = var.gitops_addons_basepath
  gitops_addons_path     = var.gitops_addons_path
  gitops_addons_revision = var.gitops_addons_revision


  argocd_namespace = "argocd"

  github_token    = var.github_token
  build_backstage = var.build_backstage

  azure_addons = {
    enable_azure_crossplane_upbound_provider = var.infrastructure_provider == "crossplane" ? true : false
    enable_cluster_api_operator              = var.infrastructure_provider == "capz" ? true : false
  }

  oss_addons = {
    enable_argocd                          = try(var.addons.enable_argocd, true) # installed by default
    argocd_chart_version                   = var.addons_versions[0].argocd_chart_version
    enable_argo_rollouts                   = try(var.addons.enable_argo_rollouts, true) # installed by default
    argo_rollouts_chart_version            = var.addons_versions[0].argo_rollouts_chart_version
    enable_argo_events                     = try(var.addons.enable_argo_events, true)    # installed by default
    enable_argo_workflows                  = try(var.addons.enable_argo_workflows, true) # installed by default
    enable_cluster_proportional_autoscaler = try(var.addons.enable_cluster_proportional_autoscaler, false)
    enable_cert_manager                    = var.infrastructure_provider == "capz" || try(var.addons.enable_cert_manager, false) ? true : false
    enable_gatekeeper                      = try(var.addons.enable_gatekeeper, false)
    enable_gpu_operator                    = try(var.addons.enable_gpu_operator, false)
    enable_ingress_nginx                   = try(var.addons.enable_ingress_nginx, false)
    enable_kargo                           = try(var.addons.enable_kargo, true) # installed by default
    kargo_chart_version                    = var.addons_versions[0].kargo_chart_version
    enable_kyverno                         = try(var.addons.enable_kyverno, false)
    enable_kube_prometheus_stack           = try(var.addons.enable_kube_prometheus_stack, false)
    enable_metrics_server                  = try(var.addons.enable_metrics_server, false)
    enable_prometheus_adapter              = try(var.addons.enable_prometheus_adapter, false)
    enable_secrets_store_csi_driver        = try(var.addons.enable_secrets_store_csi_driver, false)
    enable_vpa                             = try(var.addons.enable_vpa, false)
    enable_crossplane                      = var.infrastructure_provider == "crossplane" ? true : false
    enable_crossplane_helm_provider        = var.infrastructure_provider == "crossplane" ? true : false
    enable_crossplane_kubernetes_provider  = var.infrastructure_provider == "crossplane" ? true : false
  }
  addons = merge(local.azure_addons, local.oss_addons)

  cluster_metadata = merge(local.environment_metadata, local.addons_metadata)

  environment_metadata = {
    infrastructure_provider = var.infrastructure_provider
    akspe_identity_id       = azurerm_user_assigned_identity.akspe.client_id
    git_public_ssh_key      = var.git_public_ssh_key
  }

  addons_metadata = {
    addons_repo_url      = local.gitops_addons_url
    addons_repo_basepath = local.gitops_addons_basepath
    addons_repo_path     = local.gitops_addons_path
    addons_repo_revision = local.gitops_addons_revision
  }

  argocd_apps = {
    addons = file("${path.module}/bootstrap/addons.yaml")
  }

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/gitops-bridge-dev/gitops-bridge"
  }
}