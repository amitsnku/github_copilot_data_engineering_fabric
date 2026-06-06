# Deployment Guide — Medallion Architecture on Microsoft Fabric

Step-by-step instructions to deploy the full medallion architecture to any Fabric workspace.

---

## Prerequisites

| Requirement | Version | Install |
|---|---|---|
| PowerShell | 7.0+ | https://learn.microsoft.com/powershell/scripting/install/installing-powershell |
| Azure CLI | Latest | https://learn.microsoft.com/cli/azure/install-azure-cli |
| VS Code | Latest | https://code.visualstudio.com (optional, for Copilot agent) |
| Fabric Workspace | Any capacity | Contributor or Admin role required |
| ODBC Driver for SQL Server | 18 | https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server |

> **Fabric Capacity Note:** A Fabric trial capacity (F2 or higher) is sufficient for this deployment.
> The Fabric Warehouse requires at least an F2 SKU.

---

## Step 1 — Clone / Copy This Repository

```powershell
# Option A: Clone from GitHub
git clone https://github.com/<your-org>/copilot-fabric-medallion.git
cd copilot-fabric-medallion

# Option B: Copy files manually
# Paste the copilot_fabric_medallion folder into your working directory
```

---

## Step 2 — Authenticate with Azure

```powershell
# Log in to Azure (opens browser)
az login

# Verify correct tenant and subscription
az account show

# If you have multiple tenants, specify yours
az login --tenant "<your-tenant-id>"
```

---

## Step 3 — Find Your Fabric Workspace ID

1. Go to [app.fabric.microsoft.com](https://app.fabric.microsoft.com)
2. Click on your target workspace in the left panel
3. Look at the browser URL — it will contain:
   ```
   https://app.fabric.microsoft.com/groups/<workspace-id>/...
   ```
4. Copy the GUID (e.g. `632718e4-2ab9-4c28-a6e4-54d95836ec62`)

---

## Step 4 — Set Environment Variables

```powershell
# Set workspace ID (required)
$env:FABRIC_WORKSPACE_ID = "<your-workspace-id>"

# Verify it is set
Write-Host $env:FABRIC_WORKSPACE_ID
```

---

## Step 5 — Update Workspace ID in Deploy Script

The notebooks contain a hardcoded workspace ID used to connect to the Fabric Warehouse.
Open `scripts/deploy-medallion.ps1` and search for:

```python
ws_id  = '632718e4-2ab9-4c28-a6e4-54d95836ec62'  # Fabric workspace ID
```

Replace all 3 occurrences (one per notebook) with your own workspace ID.

> **Tip:** Use VS Code Find & Replace (`Ctrl+H`) to replace all at once.

You also need to update the warehouse name if you want a different name. Search for:
```powershell
$warehouseName = "ou_copilot_dw_poc"
```

---

## Step 6 — Validate Connectivity

```powershell
cd <repo-root>
$env:FABRIC_WORKSPACE_ID = "<your-workspace-id>"
.\scripts\fabric\Get-FabricItems.ps1
```

Expected: a list of existing items in your workspace. If you get an auth error, re-run `az login`.

---

## Step 7 — Run the Deployment Script

```powershell
.\scripts\deploy-medallion.ps1
```

The script will:

| Step | Action | Idempotent? |
|---|---|---|
| 1 | Create Fabric Warehouse `ou_copilot_dw_poc` | ✅ Skips if exists |
| 2 | Create/update `nb_01_raw_data_setup` | ✅ Updates definition if exists |
| 3 | Create/update `nb_02_quality_silver` | ✅ Updates definition if exists |
| 4 | Create/update `nb_03_semantic_views` | ✅ Updates definition if exists |
| 5 | Create pipeline `pl_medallion_etl` | ✅ Wires activities on every run |

Expected output:
```
=== STEP 1: Create Warehouse ===
  [Warehouse] 'ou_copilot_dw_poc' created (ID: xxxxxxxx-...)

=== STEP 2: Notebook 01 — Raw Data Setup ===
  [async] Polling operation ...
  [Notebook] 'nb_01_raw_data_setup' created (ID: xxxxxxxx-...)

=== STEP 3: Notebook 02 — Quality + Silver ===
  [Notebook] 'nb_02_quality_silver' created (ID: xxxxxxxx-...)

=== STEP 4: Notebook 03 — Semantic Views ===
  [Notebook] 'nb_03_semantic_views' created (ID: xxxxxxxx-...)

=== STEP 5: Pipeline — pl_medallion_etl ===
  [DataPipeline] 'pl_medallion_etl' created (ID: xxxxxxxx-...)
  [Pipeline] 'pl_medallion_etl' definition updated with 3 sequential activities.

==========================================
 MEDALLION DEPLOYMENT COMPLETE
==========================================
```

---

## Step 8 — Trigger the Pipeline

**Option A: Via PowerShell**

```powershell
$env:FABRIC_WORKSPACE_ID = "<your-workspace-id>"
$pipelineId = "<pipeline-id-from-deploy-output>"

$token = .\scripts\fabric\Get-FabricToken.ps1
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

$uri = "https://api.fabric.microsoft.com/v1/workspaces/$env:FABRIC_WORKSPACE_ID/dataPipelines/$pipelineId/jobs/instances?jobType=Pipeline"
$response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body '{}'
Write-Host "Status: $($response.StatusCode)"   # Expect 202 Accepted
```

**Option B: Via Fabric Portal**

1. Go to [app.fabric.microsoft.com](https://app.fabric.microsoft.com)
2. Navigate to your workspace
3. Find `pl_medallion_etl` pipeline
4. Click **Run**

---

## Step 9 — Monitor the Run

**Via PowerShell:**
```powershell
$runId = "<run-id-from-trigger-response>"
$statusUri = "https://api.fabric.microsoft.com/v1/workspaces/$env:FABRIC_WORKSPACE_ID/items/$pipelineId/jobs/instances/$runId"

do {
    Start-Sleep -Seconds 30
    $s = Invoke-RestMethod -Uri $statusUri -Headers $headers
    Write-Host "Status: $($s.status)"
} while ($s.status -notin @('Succeeded','Failed','Cancelled'))
```

**Via Portal:** Click the pipeline → **View run history**

---

## Step 10 — Validate Results

After a successful run, connect to the warehouse and check row counts:

```sql
-- Raw layer
SELECT 'raw.orders'    AS tbl, COUNT(*) n FROM raw.orders
UNION ALL SELECT 'raw.sales',      COUNT(*) FROM raw.sales
UNION ALL SELECT 'raw.purchases',  COUNT(*) FROM raw.purchases

-- Quality audit
SELECT check_type, status, COUNT(*) checks
FROM audit.quality_log
GROUP BY check_type, status
ORDER BY 1, 2

-- Silver layer
SELECT 'silver.fact_orders'   AS tbl, COUNT(*) n FROM silver.fact_orders
UNION ALL SELECT 'silver.fact_sales',    COUNT(*) FROM silver.fact_sales
UNION ALL SELECT 'silver.fact_purchases',COUNT(*) FROM silver.fact_purchases

-- Semantic layer
SELECT 'mv_daily_sales_summary'       AS tbl, COUNT(*) n FROM semantic.mv_daily_sales_summary
UNION ALL SELECT 'mv_monthly_revenue',         COUNT(*) FROM semantic.mv_monthly_revenue
UNION ALL SELECT 'mv_customer_lifetime_value', COUNT(*) FROM semantic.mv_customer_lifetime_value
UNION ALL SELECT 'mv_top_products',            COUNT(*) FROM semantic.mv_top_products
UNION ALL SELECT 'mv_store_performance',       COUNT(*) FROM semantic.mv_store_performance
UNION ALL SELECT 'mv_supplier_performance',    COUNT(*) FROM semantic.mv_supplier_performance
UNION ALL SELECT 'mv_sales_vs_purchases',      COUNT(*) FROM semantic.mv_sales_vs_purchases
```

---

## Redeploying to a Different Workspace

1. Update `$env:FABRIC_WORKSPACE_ID` to the new workspace GUID
2. In `scripts/deploy-medallion.ps1`, replace all 3 occurrences of the old workspace ID in the notebook content with the new one
3. Re-run `.\scripts\deploy-medallion.ps1`

The script is fully idempotent — existing assets are updated, not duplicated.

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `Failed to obtain Fabric access token` | Not authenticated | Run `az login` |
| `FABRIC_WORKSPACE_ID not set` | Missing env var | Set `$env:FABRIC_WORKSPACE_ID` |
| `Convert data from py to ipynb failed` | Notebook format error | Ensure first line is `# Fabric notebook source`; no multi-line `# META` blocks |
| `AttributeError: 'env' has no attribute 'getWorkspaceId'` | Wrong mssparkutils API | Use hardcoded workspace ID in notebooks |
| `Operation failed (Failed): 202 timeout` | Async operation timeout | Increase `$maxWait` in Wait-FabricOp helper |
| Notebook runs but warehouse is empty | Wrong warehouse name in notebook | Confirm `WAREHOUSE = 'ou_copilot_dw_poc'` matches actual warehouse name |
| Pipeline shows `NotStarted` for a long time | Fabric capacity cold start | Wait 2–3 minutes; Fabric capacity may be resuming |
