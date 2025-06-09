
data "azurerm_subscription" "current" {}

################################################################################
# Resource Group: Resource
################################################################################
resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

################################################################################
# Virtual Network: Module
################################################################################

module "network" {
  source              = "Azure/avm-res-network-virtualnetwork/azurerm"
  version             = "0.8.1"
  resource_group_name = azurerm_resource_group.this.name
  enable_telemetry    = false
  subnets = {
    aks = {
      name              = "aks"
      address_prefixes  = ["10.52.0.0/16"]
      service_endpoints = ["Microsoft.Storage"]
    }
  }
  address_space = ["10.52.0.0/16"]
  location      = azurerm_resource_group.this.location
  name          = "vnet1"
  tags          = var.tags
}


################################################################################
# AKS: Module
################################################################################

module "aks" {
  source                                          = "Azure/aks/azurerm//v4"
  version                                         = "10.1.0"

  rbac_aad_tenant_id                              = data.azurerm_client_config.current.tenant_id
  resource_group_name                             = azurerm_resource_group.this.name
  location                                        = var.location
  kubernetes_version                              = var.kubernetes_version
  orchestrator_version                            = var.kubernetes_version
  role_based_access_control_enabled               = var.role_based_access_control_enabled
  rbac_aad                                        = var.rbac_aad
  prefix                                          = var.prefix
  network_plugin                                  = var.network_plugin
  vnet_subnet                                     = { id = module.network.subnets["aks"].resource_id }
  os_disk_size_gb                                 = var.os_disk_size_gb
  os_sku                                          = var.os_sku
  sku_tier                                        = var.sku_tier
  private_cluster_enabled                         = var.private_cluster_enabled
  enable_auto_scaling                             = var.enable_auto_scaling
  enable_host_encryption                          = var.enable_host_encryption
  log_analytics_workspace_enabled                 = var.log_analytics_workspace_enabled
  agents_min_count                                = var.agents_min_count
  agents_max_count                                = var.agents_max_count
  agents_count                                    = null # Please set `agents_count` `null` while `enable_auto_scaling` is `true` to avoid possible `agents_count` changes.
  agents_max_pods                                 = var.agents_max_pods
  agents_pool_name                                = "system"
  agents_type                                     = "VirtualMachineScaleSets"
  agents_size                                     = var.agents_size
  monitor_metrics                                 = {}
  azure_policy_enabled                            = var.azure_policy_enabled
  microsoft_defender_enabled                      = var.microsoft_defender_enabled
  tags                                            = var.tags
  green_field_application_gateway_for_ingress     = var.green_field_application_gateway_for_ingress
  create_role_assignments_for_application_gateway = var.create_role_assignments_for_application_gateway

  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  agents_labels = {
    "nodepool" : "defaultnodepool"
  }

  agents_tags = {
    "Agent" : "defaultnodepoolagent"
  }

  network_policy             = var.network_policy
  net_profile_dns_service_ip = var.net_profile_dns_service_ip
  net_profile_service_cidr   = var.net_profile_service_cidr

  network_contributor_role_assigned_subnet_ids = { "aks" = module.network.subnets["aks"].resource_id }

  depends_on = [module.network]
}


################################################################################
# Workload Identity: Module
################################################################################

resource "azurerm_user_assigned_identity" "akspe" {
  name                = "akspe"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
}

resource "azurerm_role_assignment" "akspe_role_assignment" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Owner"
  principal_id         = azurerm_user_assigned_identity.akspe.principal_id
}

resource "azurerm_federated_identity_credential" "crossplane" {
  count               = var.infrastructure_provider == "crossplane" ? 1 : 0
  depends_on          = [module.aks]
  name                = "crossplane-provider-azure"
  resource_group_name = azurerm_resource_group.this.name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = module.aks.oidc_issuer_url
  parent_id           = azurerm_user_assigned_identity.akspe.id
  subject             = "system:serviceaccount:crossplane-system:azure-provider"
}

resource "azurerm_federated_identity_credential" "capz" {
  count               = var.infrastructure_provider == "capz" ? 1 : 0
  depends_on          = [module.aks]
  name                = "capz-manager-credential"
  resource_group_name = azurerm_resource_group.this.name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = module.aks.oidc_issuer_url
  parent_id           = azurerm_user_assigned_identity.akspe.id
  subject             = "system:serviceaccount:azure-infrastructure-system:capz-manager"
}

resource "azurerm_federated_identity_credential" "service_operator" {
  count               = var.infrastructure_provider == "capz" ? 1 : 0
  depends_on          = [module.aks]
  name                = "serviceoperator"
  resource_group_name = azurerm_resource_group.this.name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = module.aks.oidc_issuer_url
  parent_id           = azurerm_user_assigned_identity.akspe.id
  subject             = "system:serviceaccount:azure-infrastructure-system:azureserviceoperator-default"
}




################################################################################
# GitOps Bridge: Private ssh keys for git
################################################################################
resource "kubernetes_namespace" "argocd_namespace" {
  depends_on = [module.aks]
  metadata {
    name = "argocd"
  }
}

resource "kubernetes_secret" "git_secrets" {
  depends_on = [kubernetes_namespace.argocd_namespace]
  for_each = {
    git-addons = {
      type = "git"
      url  = var.gitops_addons_org
      # sshPrivateKey = file(pathexpand(var.git_private_ssh_key))
    }
  }
  metadata {
    name      = each.key
    namespace = kubernetes_namespace.argocd_namespace.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repo-creds"
    }
  }
  data = each.value
}


################################################################################
# GitOps Bridge: Bootstrap
################################################################################
module "gitops_bridge_bootstrap" {
  depends_on = [module.aks]
  source     = "gitops-bridge-dev/gitops-bridge/helm"

  cluster = {
    cluster_name = module.aks.aks_name
    environment  = local.environment
    metadata = merge(local.cluster_metadata,
      {
        kubelet_identity_client_id = module.aks.kubelet_identity[0].client_id
        subscription_id            = data.azurerm_subscription.current.subscription_id
        tenant_id                  = data.azurerm_subscription.current.tenant_id
    })
    addons = local.addons
  }
  apps = local.argocd_apps
  argocd = {
    namespace     = local.argocd_namespace
    chart_version = var.addons_versions[0].argocd_chart_version
  }
}
