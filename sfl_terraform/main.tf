terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
}

# ----------------------------
# Variables
# ----------------------------
variable "environment" {
  description = "Environment (dev or prod)"
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Region for shared/app resources (ACA env, ACR, KV, LA, Storage, Container App)"
  type        = string
  default     = "East US"
}

variable "data_location" {
  description = "Region for data resources (MySQL, Redis). Change this if your subscription can't provision MySQL in your preferred region."
  type        = string
  default     = "West US 2"
}

variable "enable_mysql" {
  description = "Create MySQL Flexible Server (set false if region capacity blocks provisioning)"
  type        = bool
  default     = true
}

variable "enable_redis" {
  description = "Create Azure Cache for Redis"
  type        = bool
  default     = true
}

# ----------------------------
# Locals
# ----------------------------
locals {
  project = "sfl"

  tags = {
    Environment = var.environment
    Project     = "StarCraft Fastest League"
    Owner       = "dmoon"
    ManagedBy   = "terraform"
  }
}

# ----------------------------
# Resource Groups
# ----------------------------
resource "azurerm_resource_group" "app" {
  name     = "rg-${local.project}-${var.environment}-app"
  location = var.location
  tags     = merge(local.tags, { Tier = "Application" })
}

resource "azurerm_resource_group" "shared" {
  name     = "rg-${local.project}-${var.environment}-shared"
  location = var.location
  tags     = merge(local.tags, { Tier = "Shared" })
}

resource "azurerm_resource_group" "data" {
  name     = "rg-${local.project}-${var.environment}-data"
  location = var.data_location
  tags     = merge(local.tags, { Tier = "Data" })
}

# ----------------------------
# Random suffixes for globally-unique names
# ----------------------------
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "random_password" "mysql_password" {
  length  = 20
  special = true
}

# ----------------------------
# Log Analytics (required for Container Apps Environment)
# ----------------------------
resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-${local.project}-${var.environment}-${random_string.suffix.result}"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = local.tags
}

# ----------------------------
# Azure Container Apps Environment
# ----------------------------
resource "azurerm_container_app_environment" "cae" {
  name                       = "cae-${local.project}-${var.environment}"
  location                   = azurerm_resource_group.shared.location
  resource_group_name        = azurerm_resource_group.shared.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  tags = local.tags
}

# ----------------------------
# Azure Container Registry (for your future Laravel image)
# ----------------------------
resource "azurerm_container_registry" "acr" {
  name                = "acr${local.project}${var.environment}${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  sku                 = "Basic"
  admin_enabled       = false

  tags = local.tags
}

# ----------------------------
# Storage Account (optional; safe to create now)
# ----------------------------
resource "azurerm_storage_account" "laravel" {
  name                     = "st${local.project}${var.environment}${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.shared.name
  location                 = azurerm_resource_group.shared.location
  account_tier             = "Standard"
  account_replication_type = var.environment == "prod" ? "GRS" : "LRS"

  tags = local.tags
}

# ----------------------------
# Redis Cache (Data region)
# ----------------------------
resource "azurerm_redis_cache" "laravel" {
  count               = var.enable_redis ? 1 : 0
  name                = "redis-${local.project}-${var.environment}"
  location            = azurerm_resource_group.data.location
  resource_group_name = azurerm_resource_group.data.name

  capacity            = var.environment == "prod" ? 2 : 0
  family              = "C"
  sku_name            = var.environment == "prod" ? "Standard" : "Basic"

  minimum_tls_version = "1.2"

  tags = local.tags
}

# ----------------------------
# MySQL Flexible Server (Data region; can be blocked by region capacity/access)
# Uses provider-accepted version values (5.7 or 8.0.21). Using 8.0.21.
# ----------------------------
resource "azurerm_mysql_flexible_server" "laravel" {
  count               = var.enable_mysql ? 1 : 0
  name                = "mysql-${local.project}-${var.environment}"
  resource_group_name = azurerm_resource_group.data.name
  location            = azurerm_resource_group.data.location

  administrator_login    = "sfladmin"
  administrator_password = random_password.mysql_password.result

  sku_name = var.environment == "prod" ? "GP_Standard_D2ds_v4" : "B_Standard_B1ms"
  version  = "8.0.21"

  backup_retention_days        = var.environment == "prod" ? 35 : 7
  geo_redundant_backup_enabled = var.environment == "prod" ? true : false

  tags = local.tags
}

resource "azurerm_mysql_flexible_database" "laravel" {
  count               = var.enable_mysql ? 1 : 0
  name                = var.environment == "prod" ? "starcraft_fastest_prod" : "starcraft_fastest_dev"
  resource_group_name = azurerm_resource_group.data.name
  server_name         = azurerm_mysql_flexible_server.laravel[0].name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}

# Allow Azure services (including Container Apps) to connect when using public networking (minimal for now)
resource "azurerm_mysql_flexible_server_firewall_rule" "allow_azure" {
  count               = var.enable_mysql ? 1 : 0
  name                = "AllowAzureServices"
  resource_group_name = azurerm_resource_group.data.name
  server_name         = azurerm_mysql_flexible_server.laravel[0].name
  start_ip_address    = "0.0.0.0"
  end_ip_address      = "0.0.0.0"
}

# ----------------------------
# Key Vault + Secrets
# ----------------------------
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "main" {
  name                = "kv-${local.project}-${var.environment}-${random_string.suffix.result}"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions = ["Get", "List", "Set", "Delete", "Recover", "Backup", "Restore"]
  }

  tags = local.tags
}

resource "azurerm_key_vault_secret" "mysql_password" {
  # still safe to store even if MySQL is disabled
  name         = "mysql-password"
  value        = random_password.mysql_password.result
  key_vault_id = azurerm_key_vault.main.id
}

resource "azurerm_key_vault_secret" "redis_password" {
  count        = var.enable_redis ? 1 : 0
  name         = "redis-password"
  value        = azurerm_redis_cache.laravel[0].primary_access_key
  key_vault_id = azurerm_key_vault.main.id
}

resource "azurerm_key_vault_secret" "storage_key" {
  name         = "storage-key"
  value        = azurerm_storage_account.laravel.primary_access_key
  key_vault_id = azurerm_key_vault.main.id
}

# ----------------------------
# Container App (placeholder until you push your Laravel image)
# - External ingress enabled (public)
# - Uses env vars for DB/Redis only if those are enabled
# ----------------------------
resource "azurerm_container_app" "web" {
  name                         = "ca-${local.project}-${var.environment}-web"
  resource_group_name          = azurerm_resource_group.app.name
  container_app_environment_id = azurerm_container_app_environment.cae.id
  revision_mode                = "Single"

  ingress {
    external_enabled = true
    target_port      = 80
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    container {
      name   = "web"
      image  = "mcr.microsoft.com/k8se/quickstart:latest"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "APP_ENV"
        value = var.environment == "prod" ? "production" : "development"
      }

      # DB settings only when MySQL is enabled
      dynamic "env" {
        for_each = var.enable_mysql ? [1] : []
        content {
          name  = "DB_HOST"
          value = azurerm_mysql_flexible_server.laravel[0].fqdn
        }
      }

      dynamic "env" {
        for_each = var.enable_mysql ? [1] : []
        content {
          name  = "DB_DATABASE"
          value = azurerm_mysql_flexible_database.laravel[0].name
        }
      }

      dynamic "env" {
        for_each = var.enable_mysql ? [1] : []
        content {
          name  = "DB_USERNAME"
          value = azurerm_mysql_flexible_server.laravel[0].administrator_login
        }
      }

      dynamic "env" {
        for_each = var.enable_mysql ? [1] : []
        content {
          name  = "DB_PASSWORD"
          value = random_password.mysql_password.result
        }
      }

      # Redis settings only when Redis is enabled
      dynamic "env" {
        for_each = var.enable_redis ? [1] : []
        content {
          name  = "REDIS_HOST"
          value = azurerm_redis_cache.laravel[0].hostname
        }
      }

      dynamic "env" {
        for_each = var.enable_redis ? [1] : []
        content {
          name  = "REDIS_PASSWORD"
          value = azurerm_redis_cache.laravel[0].primary_access_key
        }
      }
    }
  }

  tags = local.tags
}

# ----------------------------
# Outputs
# ----------------------------
output "resource_groups" {
  value = {
    app    = azurerm_resource_group.app.name
    shared = azurerm_resource_group.shared.name
    data   = azurerm_resource_group.data.name
  }
}

output "container_app_fqdn" {
  value = azurerm_container_app.web.ingress[0].fqdn
}

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "mysql_fqdn" {
  value = var.enable_mysql ? azurerm_mysql_flexible_server.laravel[0].fqdn : null
}

output "redis_hostname" {
  value = var.enable_redis ? azurerm_redis_cache.laravel[0].hostname : null
}