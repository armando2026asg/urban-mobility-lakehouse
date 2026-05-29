resource "azurerm_resource_group" "this" {
  name     = "rg-${var.project}-${var.environment}-weu"
  location = var.location
}

resource "azurerm_storage_account" "lakehouse" {
  name                     = "sturbanmobilitydev001"
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  is_hns_enabled = true

  tags = {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "azurerm_storage_container" "landing" {
  name                  = "landing"
  storage_account_id    = azurerm_storage_account.lakehouse.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "uc_managed" {
  name                  = "uc-managed"
  storage_account_id    = azurerm_storage_account.lakehouse.id
  container_access_type = "private"
}


/*************** Databricks related resources ********************************/
resource "azurerm_databricks_workspace" "this" {
  name                = "dbw-${var.project}-${var.environment}-weu"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "premium"

  managed_resource_group_name = "rg-${var.project}-${var.environment}-dbw-managed-weu"

  tags = {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "azurerm_databricks_access_connector" "this" {
  name                = "ac-${var.project}-${var.environment}-weu"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  identity {
    type = "SystemAssigned"
  }

  tags = {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "azurerm_role_assignment" "databricks_uc_managed_blob_contributor" {
  scope                = azurerm_storage_container.uc_managed.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_databricks_access_connector.this.identity[0].principal_id
}

resource "azurerm_role_assignment" "databricks_landing_blob_reader" {
  scope                = azurerm_storage_container.landing.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_databricks_access_connector.this.identity[0].principal_id
}
/*************** Databricks related resources END ***************************/

/********************** Azure Functions (Data ingestion) **********************/
resource "azurerm_storage_account" "function_runtime" {
  name                     = "stfuncurbanmobdev001"
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "azurerm_service_plan" "function" {
  name                = "asp-${var.project}-${var.environment}-weu"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  os_type  = "Linux"
  sku_name = "Y1"

  tags = {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "azurerm_linux_function_app" "raw_producer" {
  name                = "func-${var.project}-${var.environment}-weu"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  service_plan_id            = azurerm_service_plan.function.id
  storage_account_name       = azurerm_storage_account.function_runtime.name
  storage_account_access_key = azurerm_storage_account.function_runtime.primary_access_key

  functions_extension_version = "~4"

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      dotnet_version              = "8.0"
      use_dotnet_isolated_runtime = true
    }
  }

  app_settings = {
    FUNCTIONS_WORKER_RUNTIME = "dotnet-isolated"

    LANDING_CONTAINER_NAME = azurerm_storage_container.landing.name
    LAKEHOUSE_STORAGE_NAME = azurerm_storage_account.lakehouse.name
  }

  tags = {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "azurerm_role_assignment" "function_landing_blob_contributor" {
  scope                = azurerm_storage_container.landing.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_function_app.raw_producer.identity[0].principal_id
}
/********************** Azure Functions (Data ingestion) END **********************/


// ********************* Databricks (Control plane) **********************

resource "databricks_storage_credential" "lakehouse" {
  name = "sc-${var.project}-${var.environment}"

  azure_managed_identity {
    access_connector_id = azurerm_databricks_access_connector.this.id
  }

  comment = "Storage credential for Urban Mobility Lakehouse managed by Terraform"

  depends_on = [
    azurerm_role_assignment.databricks_uc_managed_blob_contributor,
    azurerm_role_assignment.databricks_landing_blob_reader
  ]
}

resource "databricks_external_location" "uc_managed" {
  name = "extloc-${var.project}-${var.environment}-uc-managed"

  url = "abfss://${azurerm_storage_container.uc_managed.name}@${azurerm_storage_account.lakehouse.name}.dfs.core.windows.net/"

  credential_name = databricks_storage_credential.lakehouse.name

  comment = "External location for Unity Catalog managed storage"
}

resource "databricks_external_location" "landing" {
  name = "extloc-${var.project}-${var.environment}-landing"

  url = "abfss://${azurerm_storage_container.landing.name}@${azurerm_storage_account.lakehouse.name}.dfs.core.windows.net/"

  credential_name = databricks_storage_credential.lakehouse.name

  comment = "External location for raw landing files from Urban Mobility sources"
}


resource "databricks_catalog" "mobility" {
  name         = "mobility_${var.environment}"
  storage_root = databricks_external_location.uc_managed.url

  comment = "Urban Mobility Lakehouse catalog managed by Terraform"
}

//Schemas: 

resource "databricks_schema" "bronze" {
  catalog_name = databricks_catalog.mobility.name
  name         = "bronze"
  comment      = "Bronze layer for raw Delta tables"
}

resource "databricks_schema" "silver" {
  catalog_name = databricks_catalog.mobility.name
  name         = "silver"
  comment      = "Silver layer for cleaned and normalized tables"
}

resource "databricks_schema" "gold" {
  catalog_name = databricks_catalog.mobility.name
  name         = "gold"
  comment      = "Gold layer for analytics-ready tables"
}

resource "databricks_schema" "metadata" {
  catalog_name = databricks_catalog.mobility.name
  name         = "metadata"
  comment      = "Metadata, audit, and pipeline control tables"
}

resource "databricks_schema" "quarantine" {
  catalog_name = databricks_catalog.mobility.name
  name         = "quarantine"
  comment      = "Invalid or rejected records from data quality checks"
}