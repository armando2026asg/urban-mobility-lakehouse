terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.0"
    }
  }
}

provider "azurerm" {
  features {}

  resource_provider_registrations = "none"
}

provider "databricks" {
  azure_workspace_resource_id = azurerm_databricks_workspace.this.id
}