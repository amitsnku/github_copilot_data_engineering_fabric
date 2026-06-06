<#
.SYNOPSIS
Deploy complete medallion architecture (Warehouse + 3 Notebooks + Pipeline) directly to Fabric workspace.

.DESCRIPTION
Creates the following Fabric items in the target workspace:
  - Warehouse  : copilot_dw_poc  (schemas: raw, silver, semantic, audit)
  - Notebook 1 : nb_01_raw_data_setup       (~100K synthetic rows)
  - Notebook 2 : nb_02_quality_silver       (quality checks + star schema)
  - Notebook 3 : nb_03_semantic_views       (7 pre-aggregated analytics tables)
  - Pipeline   : pl_medallion_etl           (runs all 3 notebooks sequentially)

All operations are idempotent — existing items are reused, not duplicated.

.EXAMPLE
$env:FABRIC_WORKSPACE_ID = ""
.\scripts\deploy-medallion.ps1
#>

param(
    [string]$WorkspaceId = $env:FABRIC_WORKSPACE_ID
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
    throw "WorkspaceId required. Set `$env:FABRIC_WORKSPACE_ID or pass -WorkspaceId."
}

$token   = & "$PSScriptRoot\fabric\Get-FabricToken.ps1"
$hdrs    = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
$baseUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId"

# ---------------------------------------------------------------------------
# Helper: poll an async Fabric operation until it completes
# ---------------------------------------------------------------------------
function Wait-FabricOp([string]$OperationId) {
    Write-Host "  [async] Polling operation $OperationId ..."
    do {
        Start-Sleep -Seconds 4
        $s = Invoke-RestMethod -Method Get `
             -Uri "https://api.fabric.microsoft.com/v1/operations/$OperationId" `
             -Headers $hdrs
    } while ($s.status -in @("Running", "NotStarted"))

    if ($s.status -ne "Succeeded") {
        throw "Operation failed ($($s.status)): $($s.error.message)"
    }
    Write-Host "  [async] Operation completed."
}

# ---------------------------------------------------------------------------
# Helper: find existing item by name+type, or return $null
# ---------------------------------------------------------------------------
function Find-Item([string]$DisplayName, [string]$Type) {
    $r = Invoke-RestMethod -Method Get -Uri "$baseUrl/items" -Headers $hdrs
    return ($r.value | Where-Object { $_.displayName -eq $DisplayName -and $_.type -eq $Type } | Select-Object -First 1)
}

# ---------------------------------------------------------------------------
# Helper: create Fabric item with optional notebook definition (base64 encoded)
# ---------------------------------------------------------------------------
function New-FabricItemWithDef {
    param(
        [string]$Type,
        [string]$DisplayName,
        [string]$Description = "",
        [string]$NotebookJsonContent = ""  # raw .ipynb JSON string; empty = no definition
    )

    $existing = Find-Item -DisplayName $DisplayName -Type $Type
    if ($existing) {
        # If it's a notebook with new content, push an updated definition
        if ($Type -eq "Notebook" -and $NotebookJsonContent) {
            Write-Host "  [Notebook] '$DisplayName' exists (ID: $($existing.id)). Updating definition..."
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($NotebookJsonContent))
            $updateBody = @{
                definition = @{
                    parts = @( @{ path = "notebook-content.py"; payload = $encoded; payloadType = "InlineBase64" } )
                }
            } | ConvertTo-Json -Depth 10
            $upResp = Invoke-WebRequest -Method Post `
                -Uri "$baseUrl/items/$($existing.id)/updateDefinition" `
                -Headers $hdrs -Body $updateBody
            if ($upResp.StatusCode -eq 202) {
                $opId = ($upResp.Headers["x-ms-operation-id"] | Select-Object -First 1)
                Wait-FabricOp -OperationId $opId
            }
            Write-Host "  [Notebook] '$DisplayName' definition updated."
        } else {
            Write-Host "  [$Type] '$DisplayName' already exists (ID: $($existing.id)). Reusing."
        }
        return $existing
    }

    $bodyHt = @{ displayName = $DisplayName; type = $Type; description = $Description }

    if ($NotebookJsonContent) {
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($NotebookJsonContent))
        $bodyHt.definition = @{
            parts = @( @{ path = "notebook-content.py"; payload = $encoded; payloadType = "InlineBase64" } )
        }
    }

    $body = $bodyHt | ConvertTo-Json -Depth 10

    $resp = Invoke-WebRequest -Method Post -Uri "$baseUrl/items" -Headers $hdrs -Body $body
    if ($resp.StatusCode -eq 202) {
        $opId = ($resp.Headers["x-ms-operation-id"] | Select-Object -First 1)
        Wait-FabricOp -OperationId $opId
        # Re-fetch the created item
        $existing2 = Find-Item -DisplayName $DisplayName -Type $Type
        Write-Host "  [$Type] '$DisplayName' created (ID: $($existing2.id))."
        return $existing2
    }
    $item = $resp.Content | ConvertFrom-Json
    Write-Host "  [$Type] '$DisplayName' created (ID: $($item.id))."
    return $item
}

# ===========================================================================
# STEP 1 — Warehouse
# ===========================================================================
Write-Host "`n=== STEP 1: Create Warehouse ==="

$wh = Find-Item -DisplayName "copilot_dw_poc" -Type "Warehouse"
if (-not $wh) {
    $whBody = '{"displayName":"copilot_dw_poc","description":"Medallion architecture DW: raw / silver / semantic / audit"}'
    $whResp = Invoke-WebRequest -Method Post -Uri "$baseUrl/warehouses" -Headers $hdrs -Body $whBody
    if ($whResp.StatusCode -eq 202) {
        $opId = ($whResp.Headers["x-ms-operation-id"] | Select-Object -First 1)
        Wait-FabricOp -OperationId $opId
        $wh = Find-Item -DisplayName "copilot_dw_poc" -Type "Warehouse"
    } else {
        $wh = $whResp.Content | ConvertFrom-Json
    }
    Write-Host "  [Warehouse] 'copilot_dw_poc' created (ID: $($wh.id))."
} else {
    Write-Host "  [Warehouse] 'copilot_dw_poc' already exists (ID: $($wh.id))."
}

# ===========================================================================
# STEP 2 — Notebook 01: Raw Data Setup
# ===========================================================================
Write-Host "`n=== STEP 2: Notebook 01 — Raw Data Setup ==="

$nb01Json = @'
# Fabric notebook source

# MARKDOWN ********************
# ## NB-01 | Raw Data Setup
# Generates ~100K synthetic rows with ~5% quality issues:
# - raw.orders 30K | raw.sales 60K | raw.purchases 10K

# CELL ********************

import pyodbc, struct
from notebookutils import mssparkutils

WAREHOUSE = 'copilot_dw_poc'
ws_id  = ''  # Fabric workspace ID
server = f'{ws_id}.datawarehouse.fabric.microsoft.com'
tok    = mssparkutils.credentials.getToken('https://database.windows.net/')
tb     = tok.encode('utf-16-le')
ts     = struct.pack(f'<I{len(tb)}s', len(tb), tb)
conn   = pyodbc.connect(
    f'DRIVER={{ODBC Driver 18 for SQL Server}};SERVER={server};DATABASE={WAREHOUSE};Encrypt=yes;TrustServerCertificate=no;',
    attrs_before={1256: ts})
conn.autocommit = True
cursor = conn.cursor()

def run_sql(cur, sql, desc=''):
    cur.execute(sql)
    if desc:
        print(f'[OK] {desc}')

print(f'Connected: {WAREHOUSE}')

# METADATA ********************
# META {}

# CELL ********************

for schema, sql in [
    ('raw',      "IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name='raw')      EXEC('CREATE SCHEMA raw')"),
    ('silver',   "IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name='silver')   EXEC('CREATE SCHEMA silver')"),
    ('semantic', "IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name='semantic') EXEC('CREATE SCHEMA semantic')"),
    ('audit',    "IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name='audit')    EXEC('CREATE SCHEMA audit')"),
]:
    run_sql(cursor, sql, f'Schema [{schema}] ensured')

# METADATA ********************
# META {}

# CELL ********************

run_sql(cursor, "IF OBJECT_ID('raw.orders','U') IS NOT NULL DROP TABLE raw.orders", 'Drop raw.orders')
run_sql(cursor,
    "CREATE TABLE raw.orders ("
    "order_id NVARCHAR(50) NOT NULL, customer_id NVARCHAR(50), order_date DATETIME2, "
    "order_status NVARCHAR(20), payment_method NVARCHAR(30), total_amount DECIMAL(18,2), "
    "currency NVARCHAR(3), store_id NVARCHAR(50), channel NVARCHAR(30), "
    "source_system NVARCHAR(50), ingested_at DATETIME2 DEFAULT GETDATE())",
    'Create raw.orders')

sql_parts = [
    "WITH L0 AS (SELECT 1 n UNION ALL SELECT 1),",
    "L1 AS (SELECT 1 n FROM L0 a,L0 b),L2 AS (SELECT 1 n FROM L1 a,L1 b),",
    "L3 AS (SELECT 1 n FROM L2 a,L2 b),L4 AS (SELECT 1 n FROM L3 a,L3 b),",
    "nums AS (SELECT TOP 30000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) rn FROM L4)",
    "INSERT INTO raw.orders (order_id,customer_id,order_date,order_status,payment_method,total_amount,currency,store_id,channel,source_system)",
    "SELECT 'ORD-'+RIGHT('000000'+CAST(rn AS VARCHAR(6)),6),",
    "  CASE WHEN ABS(CHECKSUM(NEWID()))%100<3 THEN NULL ELSE 'CUST-'+RIGHT('00000'+CAST(ABS(CHECKSUM(NEWID()))%5000+1 AS VARCHAR(5)),5) END,",
    "  CASE WHEN ABS(CHECKSUM(NEWID()))%100<2 THEN DATEADD(DAY,ABS(CHECKSUM(NEWID()))%30+1,GETDATE()) ELSE DATEADD(MINUTE,-(ABS(CHECKSUM(NEWID()))%525600),GETDATE()) END,",
    "  CASE WHEN ABS(CHECKSUM(NEWID()))%100<1 THEN 'UNKNOWN' ELSE CHOOSE(ABS(CHECKSUM(NEWID()))%4+1,'PENDING','PROCESSING','SHIPPED','DELIVERED') END,",
    "  CHOOSE(ABS(CHECKSUM(NEWID()))%4+1,'CREDIT_CARD','DEBIT_CARD','PAYPAL','BANK_TRANSFER'),",
    "  CASE WHEN ABS(CHECKSUM(NEWID()))%100<2 THEN -ROUND(CAST(ABS(CHECKSUM(NEWID()))%50000+1000 AS DECIMAL(18,2))/100.0,2) ELSE ROUND(CAST(ABS(CHECKSUM(NEWID()))%95000+1000 AS DECIMAL(18,2))/100.0,2) END,",
    "  'GBP','STORE-'+RIGHT('000'+CAST(ABS(CHECKSUM(NEWID()))%50+1 AS VARCHAR(3)),3),",
    "  CHOOSE(ABS(CHECKSUM(NEWID()))%3+1,'ONLINE','IN_STORE','MOBILE'),",
    "  CHOOSE(ABS(CHECKSUM(NEWID()))%2+1,'SYS_A','SYS_B') FROM nums"
]
run_sql(cursor, ' '.join(sql_parts), 'raw.orders: 30,000 rows')

# METADATA ********************
# META {}

# CELL ********************

run_sql(cursor, "IF OBJECT_ID('raw.sales','U') IS NOT NULL DROP TABLE raw.sales", 'Drop raw.sales')
run_sql(cursor,
    "CREATE TABLE raw.sales ("
    "sale_id NVARCHAR(50) NOT NULL, order_id NVARCHAR(50), product_id NVARCHAR(50), "
    "product_name NVARCHAR(200), category NVARCHAR(100), quantity INT, "
    "unit_price DECIMAL(18,2), discount_pct DECIMAL(5,2), net_amount DECIMAL(18,2), "
    "sale_date DATETIME2, store_id NVARCHAR(50), region NVARCHAR(50), ingested_at DATETIME2 DEFAULT GETDATE())",
    'Create raw.sales')

sql_parts = [
    "WITH L0 AS (SELECT 1 n UNION ALL SELECT 1),L1 AS (SELECT 1 n FROM L0 a,L0 b),",
    "L2 AS (SELECT 1 n FROM L1 a,L1 b),L3 AS (SELECT 1 n FROM L2 a,L2 b),L4 AS (SELECT 1 n FROM L3 a,L3 b),",
    "nums AS (SELECT TOP 60000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) rn FROM L4)",
    "INSERT INTO raw.sales (sale_id,order_id,product_id,product_name,category,quantity,unit_price,discount_pct,net_amount,sale_date,store_id,region)",
    "SELECT 'SALE-'+RIGHT('000000'+CAST(rn AS VARCHAR(6)),6),",
    "  CASE WHEN ABS(CHECKSUM(NEWID()))%100<2 THEN 'ORD-999999' ELSE 'ORD-'+RIGHT('000000'+CAST(ABS(CHECKSUM(NEWID()))%30000+1 AS VARCHAR(6)),6) END,",
    "  'PROD-'+RIGHT('000'+CAST(ABS(CHECKSUM(NEWID()))%500+1 AS VARCHAR(3)),3),",
    "  CHOOSE(ABS(CHECKSUM(NEWID()))%20+1,'Laptop Pro 15','Wireless Mouse','USB-C Hub','Mechanical Keyboard','Monitor 27in','Headphones BT','Webcam HD','Desk Lamp LED','Phone Stand','Cable USB','SSD 1TB','RAM 16GB','Graphics Card','CPU Cooler','Power Supply','Network Switch','Router WiFi6','Smart Speaker','Tablet 10in','E-Reader'),",
    "  CHOOSE(ABS(CHECKSUM(NEWID()))%5+1,'Electronics','Accessories','Storage','Networking','Computing'),",
    "  ABS(CHECKSUM(NEWID()))%10+1,",
    "  ROUND(CAST(ABS(CHECKSUM(NEWID()))%90000+500 AS DECIMAL(18,2))/100.0,2),",
    "  ROUND(CAST(ABS(CHECKSUM(NEWID()))%2500 AS DECIMAL(5,2))/100.0,2), 0.00,",
    "  DATEADD(MINUTE,-(ABS(CHECKSUM(NEWID()))%525600),GETDATE()),",
    "  'STORE-'+RIGHT('000'+CAST(ABS(CHECKSUM(NEWID()))%50+1 AS VARCHAR(3)),3),",
    "  CHOOSE(ABS(CHECKSUM(NEWID()))%5+1,'North','South','East','West','Central') FROM nums"
]
run_sql(cursor, ' '.join(sql_parts), 'raw.sales: 60,000 rows')
run_sql(cursor, "UPDATE raw.sales SET net_amount=ROUND(CAST(quantity AS DECIMAL(18,2))*unit_price*(1.0-discount_pct/100.0),2)", 'net_amount calculated')

# METADATA ********************
# META {}

# CELL ********************

run_sql(cursor, "IF OBJECT_ID('raw.purchases','U') IS NOT NULL DROP TABLE raw.purchases", 'Drop raw.purchases')
run_sql(cursor,
    "CREATE TABLE raw.purchases ("
    "purchase_id NVARCHAR(50) NOT NULL, supplier_id NVARCHAR(50), supplier_name NVARCHAR(200), "
    "product_id NVARCHAR(50), product_name NVARCHAR(200), quantity INT, "
    "unit_cost DECIMAL(18,2), total_cost DECIMAL(18,2), purchase_date DATETIME2, "
    "expected_delivery DATETIME2, actual_delivery DATETIME2, purchase_status NVARCHAR(20), "
    "store_id NVARCHAR(50), ingested_at DATETIME2 DEFAULT GETDATE())",
    'Create raw.purchases')

sql_parts = [
    "WITH L0 AS (SELECT 1 n UNION ALL SELECT 1),L1 AS (SELECT 1 n FROM L0 a,L0 b),",
    "L2 AS (SELECT 1 n FROM L1 a,L1 b),L3 AS (SELECT 1 n FROM L2 a,L2 b),",
    "nums AS (SELECT TOP 10000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) rn FROM L3 a,L3 b)",
    "INSERT INTO raw.purchases (purchase_id,supplier_id,supplier_name,product_id,product_name,quantity,unit_cost,total_cost,purchase_date,expected_delivery,actual_delivery,purchase_status,store_id)",
    "SELECT 'PUR-'+RIGHT('000000'+CAST(rn AS VARCHAR(6)),6),",
    "  'SUPP-'+RIGHT('000'+CAST(ABS(CHECKSUM(NEWID()))%100+1 AS VARCHAR(3)),3),",
    "  CHOOSE(ABS(CHECKSUM(NEWID()))%10+1,'TechSupply Ltd','Global Electronics Co','Digital Parts Inc','EuroTech GmbH','Pacific Components','Nordic Electronics','UK Parts Direct','Fast Electronics','Premier Components','Alliance Tech'),",
    "  'PROD-'+RIGHT('000'+CAST(ABS(CHECKSUM(NEWID()))%500+1 AS VARCHAR(3)),3),",
    "  CHOOSE(ABS(CHECKSUM(NEWID()))%20+1,'Laptop Pro 15','Wireless Mouse','USB-C Hub','Mechanical Keyboard','Monitor 27in','Headphones BT','Webcam HD','Desk Lamp LED','Phone Stand','Cable USB','SSD 1TB','RAM 16GB','Graphics Card','CPU Cooler','Power Supply','Network Switch','Router WiFi6','Smart Speaker','Tablet 10in','E-Reader'),",
    "  ABS(CHECKSUM(NEWID()))%100+10, ROUND(CAST(ABS(CHECKSUM(NEWID()))%50000+500 AS DECIMAL(18,2))/100.0,2), 0.00,",
    "  DATEADD(MINUTE,-(ABS(CHECKSUM(NEWID()))%525600),GETDATE()),",
    "  DATEADD(DAY,ABS(CHECKSUM(NEWID()))%14+3,DATEADD(MINUTE,-(ABS(CHECKSUM(NEWID()))%525600),GETDATE())),",
    "  DATEADD(DAY,ABS(CHECKSUM(NEWID()))%20+2,DATEADD(MINUTE,-(ABS(CHECKSUM(NEWID()))%525600),GETDATE())),",
    "  CHOOSE(ABS(CHECKSUM(NEWID()))%4+1,'ORDERED','IN_TRANSIT','DELIVERED','CANCELLED'),",
    "  'STORE-'+RIGHT('000'+CAST(ABS(CHECKSUM(NEWID()))%50+1 AS VARCHAR(3)),3) FROM nums"
]
run_sql(cursor, ' '.join(sql_parts), 'raw.purchases: 10,000 rows')
run_sql(cursor, "UPDATE raw.purchases SET total_cost=ROUND(CAST(quantity AS DECIMAL(18,2))*unit_cost,2)", 'total_cost calculated')

# METADATA ********************
# META {}

# CELL ********************

print('--- Raw Layer Counts ---')
for tbl in ['raw.orders', 'raw.sales', 'raw.purchases']:
    cursor.execute(f'SELECT COUNT(*) FROM {tbl}')
    print(f'  {tbl}: {cursor.fetchone()[0]:,}')
conn.close()
print('NB-01 done.')

# METADATA ********************
# META {}
'@

$nb01 = New-FabricItemWithDef -Type "Notebook" -DisplayName "nb_01_raw_data_setup" `
    -Description "Medallion: Raw layer — generates 100K synthetic transactions" `
    -NotebookJsonContent $nb01Json

# ===========================================================================
# STEP 3 — Notebook 02: Quality + Silver
# ===========================================================================
Write-Host "`n=== STEP 3: Notebook 02 — Quality + Silver ==="

$nb02Json = @'
# Fabric notebook source

# MARKDOWN ********************
# ## NB-02 | Quality Checks + Silver Layer
# Runs 12 quality checks logged to audit.quality_log, then builds star schema:
# dims: dim_date, dim_customer, dim_product, dim_supplier, dim_store
# facts: fact_orders, fact_sales, fact_purchases

# CELL ********************

import pyodbc, struct, uuid
from notebookutils import mssparkutils

WAREHOUSE = 'copilot_dw_poc'
ws_id  = ''  # Fabric workspace ID
server = f'{ws_id}.datawarehouse.fabric.microsoft.com'
tok    = mssparkutils.credentials.getToken('https://database.windows.net/')
tb     = tok.encode('utf-16-le')
ts     = struct.pack(f'<I{len(tb)}s', len(tb), tb)
conn   = pyodbc.connect(
    f'DRIVER={{ODBC Driver 18 for SQL Server}};SERVER={server};DATABASE={WAREHOUSE};Encrypt=yes;TrustServerCertificate=no;',
    attrs_before={1256: ts})
conn.autocommit = True
cursor = conn.cursor()

def run_sql(cur, sql, desc=''):
    cur.execute(sql)
    if desc:
        print(f'[OK] {desc}')

print(f'Connected: {WAREHOUSE}')

# METADATA ********************
# META {}

# CELL ********************

run_sql(cursor, "IF OBJECT_ID('audit.quality_log','U') IS NOT NULL DROP TABLE audit.quality_log", 'Drop quality_log')
run_sql(cursor,
    "CREATE TABLE audit.quality_log ("
    "log_id INT IDENTITY(1,1), run_id NVARCHAR(50), table_name NVARCHAR(100), "
    "check_name NVARCHAR(200), check_type NVARCHAR(50), total_records INT, "
    "failed_records INT, pass_rate DECIMAL(8,4), status NVARCHAR(10), "
    "logged_at DATETIME2 DEFAULT GETDATE())",
    'Create audit.quality_log')

RUN_ID = str(uuid.uuid4())
print(f'Quality Run ID: {RUN_ID}')

def run_check(table, check_name, check_type, sql_total, sql_failed):
    cursor.execute(sql_total);  total  = cursor.fetchone()[0] or 1
    cursor.execute(sql_failed); failed = cursor.fetchone()[0] or 0
    rate   = round((total - failed) / total * 100, 4)
    status = 'PASS' if failed == 0 else ('WARN' if failed / total < 0.1 else 'FAIL')
    cursor.execute(
        "INSERT INTO audit.quality_log (run_id,table_name,check_name,check_type,total_records,failed_records,pass_rate,status) VALUES (?,?,?,?,?,?,?,?)",
        RUN_ID, table, check_name, check_type, total, failed, rate, status)
    print(f'[{status}] {table} | {check_name}: {failed}/{total} failed ({rate:.2f}% pass)')

# METADATA ********************
# META {}

# CELL ********************

print('--- Quality: raw.orders ---')
run_check('raw.orders', 'NULL customer_id',    'Completeness',       'SELECT COUNT(*) FROM raw.orders', 'SELECT COUNT(*) FROM raw.orders WHERE customer_id IS NULL')
run_check('raw.orders', 'Negative amount',     'Validity',           'SELECT COUNT(*) FROM raw.orders', 'SELECT COUNT(*) FROM raw.orders WHERE total_amount < 0')
run_check('raw.orders', 'Future order_date',   'Validity',           'SELECT COUNT(*) FROM raw.orders', 'SELECT COUNT(*) FROM raw.orders WHERE order_date > GETDATE()')
run_check('raw.orders', 'Invalid status',      'Validity',           'SELECT COUNT(*) FROM raw.orders', "SELECT COUNT(*) FROM raw.orders WHERE order_status NOT IN ('PENDING','PROCESSING','SHIPPED','DELIVERED')")
run_check('raw.orders', 'Duplicate order_id',  'Uniqueness',         'SELECT COUNT(*) FROM raw.orders', 'SELECT COUNT(*)-COUNT(DISTINCT order_id) FROM raw.orders')

print('--- Quality: raw.sales ---')
run_check('raw.sales',  'NULL order_id',       'Completeness',       'SELECT COUNT(*) FROM raw.sales',  'SELECT COUNT(*) FROM raw.sales WHERE order_id IS NULL')
run_check('raw.sales',  'Orphaned order_id',   'Ref. Integrity',     'SELECT COUNT(*) FROM raw.sales',  'SELECT COUNT(*) FROM raw.sales WHERE order_id NOT IN (SELECT order_id FROM raw.orders)')
run_check('raw.sales',  'Zero/neg quantity',   'Validity',           'SELECT COUNT(*) FROM raw.sales',  'SELECT COUNT(*) FROM raw.sales WHERE quantity <= 0')
run_check('raw.sales',  'Negative net_amount', 'Validity',           'SELECT COUNT(*) FROM raw.sales',  'SELECT COUNT(*) FROM raw.sales WHERE net_amount < 0')

print('--- Quality: raw.purchases ---')
run_check('raw.purchases', 'NULL supplier_id', 'Completeness',       'SELECT COUNT(*) FROM raw.purchases', 'SELECT COUNT(*) FROM raw.purchases WHERE supplier_id IS NULL')
run_check('raw.purchases', 'Invalid status',   'Validity',           'SELECT COUNT(*) FROM raw.purchases', "SELECT COUNT(*) FROM raw.purchases WHERE purchase_status NOT IN ('ORDERED','IN_TRANSIT','DELIVERED','CANCELLED')")
run_check('raw.purchases', 'Negative cost',    'Validity',           'SELECT COUNT(*) FROM raw.purchases', 'SELECT COUNT(*) FROM raw.purchases WHERE total_cost < 0')

cursor.execute("SELECT status, COUNT(*) n FROM audit.quality_log WHERE run_id=? GROUP BY status", RUN_ID)
print('\n--- Quality Summary ---')
for r in cursor.fetchall():
    print(f'  {r[0]}: {r[1]}')

# METADATA ********************
# META {}

# CELL ********************

# Silver DDL — drop in dependency order then recreate
for t in ['silver.fact_purchases','silver.fact_sales','silver.fact_orders',
          'silver.dim_store','silver.dim_supplier','silver.dim_product','silver.dim_customer','silver.dim_date']:
    run_sql(cursor, f"IF OBJECT_ID('{t}','U') IS NOT NULL DROP TABLE {t}", f'Drop {t}')

run_sql(cursor, "CREATE TABLE silver.dim_date (date_key INT NOT NULL, full_date DATE, year INT, quarter INT, month INT, month_name NVARCHAR(20), week_of_year INT, day_of_month INT, day_of_week INT, day_name NVARCHAR(20), is_weekend BIT)", 'dim_date')
run_sql(cursor, "CREATE TABLE silver.dim_customer (customer_key INT IDENTITY(1,1), customer_id NVARCHAR(50), customer_name NVARCHAR(200), city NVARCHAR(100), country NVARCHAR(10), customer_segment NVARCHAR(50), first_order_date DATE, valid_from DATETIME2, valid_to DATETIME2, is_current BIT DEFAULT 1)", 'dim_customer')
run_sql(cursor, "CREATE TABLE silver.dim_product (product_key INT IDENTITY(1,1), product_id NVARCHAR(50), product_name NVARCHAR(200), category NVARCHAR(100), subcategory NVARCHAR(100), brand NVARCHAR(100), list_price DECIMAL(18,2), is_active BIT DEFAULT 1)", 'dim_product')
run_sql(cursor, "CREATE TABLE silver.dim_supplier (supplier_key INT IDENTITY(1,1), supplier_id NVARCHAR(50), supplier_name NVARCHAR(200), country NVARCHAR(10), payment_terms NVARCHAR(20), is_active BIT DEFAULT 1)", 'dim_supplier')
run_sql(cursor, "CREATE TABLE silver.dim_store (store_key INT IDENTITY(1,1), store_id NVARCHAR(50), store_name NVARCHAR(200), city NVARCHAR(100), region NVARCHAR(50), country NVARCHAR(10), store_type NVARCHAR(30))", 'dim_store')
run_sql(cursor, "CREATE TABLE silver.fact_orders (order_key INT IDENTITY(1,1), order_id NVARCHAR(50), customer_key INT, store_key INT, order_date_key INT, order_status NVARCHAR(20), payment_method NVARCHAR(30), channel NVARCHAR(30), total_amount DECIMAL(18,2), item_count INT, loaded_at DATETIME2 DEFAULT GETDATE())", 'fact_orders')
run_sql(cursor, "CREATE TABLE silver.fact_sales (sale_key INT IDENTITY(1,1), sale_id NVARCHAR(50), order_key INT, product_key INT, store_key INT, sale_date_key INT, quantity INT, unit_price DECIMAL(18,2), discount_pct DECIMAL(5,2), net_amount DECIMAL(18,2), loaded_at DATETIME2 DEFAULT GETDATE())", 'fact_sales')
run_sql(cursor, "CREATE TABLE silver.fact_purchases (purchase_key INT IDENTITY(1,1), purchase_id NVARCHAR(50), supplier_key INT, product_key INT, store_key INT, purchase_date_key INT, quantity INT, unit_cost DECIMAL(18,2), total_cost DECIMAL(18,2), purchase_status NVARCHAR(20), delivery_days INT, loaded_at DATETIME2 DEFAULT GETDATE())", 'fact_purchases')
print('[OK] Silver DDL complete')

# METADATA ********************
# META {}

# CELL ********************

# Populate dimensions
run_sql(cursor, ' '.join([
    "WITH L0 AS (SELECT 1 n UNION ALL SELECT 1),L1 AS (SELECT 1 n FROM L0 a,L0 b),L2 AS (SELECT 1 n FROM L1 a,L1 b),L3 AS (SELECT 1 n FROM L2 a,L2 b),L4 AS (SELECT 1 n FROM L3 a,L3 b),",
    "dates AS (SELECT TOP 730 CAST(DATEADD(DAY,-(ROW_NUMBER() OVER (ORDER BY (SELECT NULL))-1),CAST(GETDATE() AS DATE)) AS DATE) dt FROM L4)",
    "INSERT INTO silver.dim_date (date_key,full_date,year,quarter,month,month_name,week_of_year,day_of_month,day_of_week,day_name,is_weekend)",
    "SELECT YEAR(dt)*10000+MONTH(dt)*100+DAY(dt),dt,YEAR(dt),DATEPART(QUARTER,dt),MONTH(dt),DATENAME(MONTH,dt),DATEPART(WEEK,dt),DAY(dt),DATEPART(WEEKDAY,dt),DATENAME(WEEKDAY,dt),",
    "CASE WHEN DATEPART(WEEKDAY,dt) IN (1,7) THEN 1 ELSE 0 END FROM dates"
]), 'dim_date: 730 days')

run_sql(cursor, ' '.join([
    "INSERT INTO silver.dim_customer (customer_id,customer_name,city,country,customer_segment,first_order_date,valid_from,valid_to,is_current)",
    "SELECT o.customer_id,'Customer '+o.customer_id,",
    "CHOOSE(ABS(CHECKSUM(o.customer_id))%10+1,'London','Manchester','Birmingham','Leeds','Glasgow','Liverpool','Bristol','Sheffield','Edinburgh','Cardiff'),",
    "'GB',CHOOSE(ABS(CHECKSUM(o.customer_id))%3+1,'Premium','Standard','Basic'),",
    "CAST(MIN(o.order_date) AS DATE),GETDATE(),CAST('9999-12-31' AS DATETIME2),1",
    "FROM raw.orders o WHERE o.customer_id IS NOT NULL AND o.total_amount>=0 AND o.order_date<=GETDATE()",
    "AND o.order_status IN ('PENDING','PROCESSING','SHIPPED','DELIVERED') GROUP BY o.customer_id"
]), 'dim_customer populated')

run_sql(cursor, ' '.join([
    "INSERT INTO silver.dim_product (product_id,product_name,category,subcategory,brand,list_price,is_active)",
    "SELECT s.product_id,MAX(s.product_name),MAX(s.category),",
    "CASE MAX(s.category) WHEN 'Electronics' THEN 'Computers' WHEN 'Accessories' THEN 'Peripherals'",
    "WHEN 'Storage' THEN 'Data Storage' WHEN 'Networking' THEN 'Infrastructure' ELSE 'General' END,",
    "'BrandX',ROUND(AVG(s.unit_price),2),1 FROM raw.sales s WHERE s.quantity>0 GROUP BY s.product_id"
]), 'dim_product populated')

run_sql(cursor, ' '.join([
    "INSERT INTO silver.dim_supplier (supplier_id,supplier_name,country,payment_terms,is_active)",
    "SELECT DISTINCT p.supplier_id,MAX(p.supplier_name) OVER (PARTITION BY p.supplier_id),",
    "CHOOSE(ABS(CHECKSUM(p.supplier_id))%4+1,'GB','DE','FR','US'),",
    "CHOOSE(ABS(CHECKSUM(p.supplier_id))%3+1,'Net30','Net60','Net90'),1",
    "FROM raw.purchases p WHERE p.supplier_id IS NOT NULL"
]), 'dim_supplier populated')

run_sql(cursor, ' '.join([
    "WITH s AS (SELECT DISTINCT store_id FROM raw.orders WHERE store_id IS NOT NULL",
    "  UNION SELECT DISTINCT store_id FROM raw.sales WHERE store_id IS NOT NULL)",
    "INSERT INTO silver.dim_store (store_id,store_name,city,region,country,store_type)",
    "SELECT store_id,'Store '+store_id,",
    "CHOOSE(ABS(CHECKSUM(store_id))%10+1,'London','Manchester','Birmingham','Leeds','Glasgow','Liverpool','Bristol','Sheffield','Edinburgh','Cardiff'),",
    "CHOOSE(ABS(CHECKSUM(store_id))%4+1,'North','South','East','West'),'GB',",
    "CHOOSE(ABS(CHECKSUM(store_id))%2+1,'Flagship','Standard') FROM s"
]), 'dim_store populated')

# METADATA ********************
# META {}

# CELL ********************

# Populate facts
run_sql(cursor, ' '.join([
    "INSERT INTO silver.fact_orders (order_id,customer_key,store_key,order_date_key,order_status,payment_method,channel,total_amount,item_count)",
    "SELECT o.order_id,dc.customer_key,ds.store_key,YEAR(o.order_date)*10000+MONTH(o.order_date)*100+DAY(o.order_date),",
    "o.order_status,o.payment_method,o.channel,o.total_amount,COALESCE(sc.cnt,0)",
    "FROM raw.orders o JOIN silver.dim_customer dc ON dc.customer_id=o.customer_id",
    "JOIN silver.dim_store ds ON ds.store_id=o.store_id",
    "LEFT JOIN (SELECT order_id,COUNT(*) cnt FROM raw.sales GROUP BY order_id) sc ON sc.order_id=o.order_id",
    "WHERE o.customer_id IS NOT NULL AND o.total_amount>=0 AND o.order_date<=GETDATE()",
    "AND o.order_status IN ('PENDING','PROCESSING','SHIPPED','DELIVERED')"
]), 'fact_orders populated')

run_sql(cursor, ' '.join([
    "INSERT INTO silver.fact_sales (sale_id,order_key,product_key,store_key,sale_date_key,quantity,unit_price,discount_pct,net_amount)",
    "SELECT s.sale_id,fo.order_key,dp.product_key,ds.store_key,",
    "YEAR(s.sale_date)*10000+MONTH(s.sale_date)*100+DAY(s.sale_date),",
    "s.quantity,s.unit_price,s.discount_pct,s.net_amount",
    "FROM raw.sales s JOIN silver.fact_orders fo ON fo.order_id=s.order_id",
    "JOIN silver.dim_product dp ON dp.product_id=s.product_id",
    "JOIN silver.dim_store ds ON ds.store_id=s.store_id",
    "WHERE s.quantity>0 AND s.net_amount>=0"
]), 'fact_sales populated')

run_sql(cursor, ' '.join([
    "INSERT INTO silver.fact_purchases (purchase_id,supplier_key,product_key,store_key,purchase_date_key,quantity,unit_cost,total_cost,purchase_status,delivery_days)",
    "SELECT p.purchase_id,dsp.supplier_key,dp.product_key,ds.store_key,",
    "YEAR(p.purchase_date)*10000+MONTH(p.purchase_date)*100+DAY(p.purchase_date),",
    "p.quantity,p.unit_cost,p.total_cost,p.purchase_status,",
    "CASE WHEN p.actual_delivery IS NOT NULL THEN DATEDIFF(DAY,p.purchase_date,p.actual_delivery) ELSE NULL END",
    "FROM raw.purchases p JOIN silver.dim_supplier dsp ON dsp.supplier_id=p.supplier_id",
    "JOIN silver.dim_product dp ON dp.product_id=p.product_id",
    "JOIN silver.dim_store ds ON ds.store_id=p.store_id",
    "WHERE p.total_cost>=0 AND p.supplier_id IS NOT NULL",
    "AND p.purchase_status IN ('ORDERED','IN_TRANSIT','DELIVERED','CANCELLED')"
]), 'fact_purchases populated')

print('--- Silver Counts ---')
for t in ['silver.dim_date','silver.dim_customer','silver.dim_product','silver.dim_supplier','silver.dim_store',
          'silver.fact_orders','silver.fact_sales','silver.fact_purchases']:
    cursor.execute(f'SELECT COUNT(*) FROM {t}')
    print(f'  {t}: {cursor.fetchone()[0]:,}')
conn.close()
print('NB-02 done.')

# METADATA ********************
# META {}
'@

$nb02 = New-FabricItemWithDef -Type "Notebook" -DisplayName "nb_02_quality_silver" `
    -Description "Medallion: Quality checks + Silver star schema" `
    -NotebookJsonContent $nb02Json

# ===========================================================================
# STEP 4 — Notebook 03: Semantic Views
# ===========================================================================
Write-Host "`n=== STEP 4: Notebook 03 — Semantic Views ==="

$nb03Json = @'
# Fabric notebook source

# MARKDOWN ********************
# ## NB-03 | Semantic Layer - 7 Materialized View Tables
# 1. mv_daily_sales_summary  2. mv_monthly_revenue  3. mv_customer_lifetime_value
# 4. mv_top_products  5. mv_store_performance  6. mv_supplier_performance  7. mv_sales_vs_purchases

# CELL ********************

import pyodbc, struct
from notebookutils import mssparkutils

WAREHOUSE = 'copilot_dw_poc'
ws_id  = ''  # Fabric workspace ID
server = f'{ws_id}.datawarehouse.fabric.microsoft.com'
tok    = mssparkutils.credentials.getToken('https://database.windows.net/')
tb     = tok.encode('utf-16-le')
ts     = struct.pack(f'<I{len(tb)}s', len(tb), tb)
conn   = pyodbc.connect(
    f'DRIVER={{ODBC Driver 18 for SQL Server}};SERVER={server};DATABASE={WAREHOUSE};Encrypt=yes;TrustServerCertificate=no;',
    attrs_before={1256: ts})
conn.autocommit = True
cursor = conn.cursor()

def run_sql(cur, sql, desc=''):
    cur.execute(sql)
    if desc:
        print(f'[OK] {desc}')

print(f'Connected: {WAREHOUSE}')

# METADATA ********************
# META {}

# CELL ********************

for t in ['semantic.mv_sales_vs_purchases','semantic.mv_supplier_performance',
          'semantic.mv_store_performance','semantic.mv_top_products',
          'semantic.mv_customer_lifetime_value','semantic.mv_monthly_revenue',
          'semantic.mv_daily_sales_summary']:
    run_sql(cursor, f"IF OBJECT_ID('{t}','U') IS NOT NULL DROP TABLE {t}", f'Drop {t}')

run_sql(cursor, "CREATE TABLE semantic.mv_daily_sales_summary (full_date DATE, total_orders INT, total_quantity INT, gross_revenue DECIMAL(18,2), net_revenue DECIMAL(18,2), avg_order_value DECIMAL(18,2), refreshed_at DATETIME2 DEFAULT GETDATE())", 'mv_daily_sales_summary')
run_sql(cursor, "CREATE TABLE semantic.mv_monthly_revenue (year INT, month INT, month_name NVARCHAR(20), category NVARCHAR(100), total_orders INT, total_quantity INT, net_revenue DECIMAL(18,2), refreshed_at DATETIME2 DEFAULT GETDATE())", 'mv_monthly_revenue')
run_sql(cursor, "CREATE TABLE semantic.mv_customer_lifetime_value (customer_key INT, customer_id NVARCHAR(50), customer_name NVARCHAR(200), customer_segment NVARCHAR(50), total_orders INT, total_spend DECIMAL(18,2), avg_order_value DECIMAL(18,2), first_purchase_date DATE, last_purchase_date DATE, ltv_tier NVARCHAR(20), refreshed_at DATETIME2 DEFAULT GETDATE())", 'mv_customer_lifetime_value')
run_sql(cursor, "CREATE TABLE semantic.mv_top_products (product_key INT, product_id NVARCHAR(50), product_name NVARCHAR(200), category NVARCHAR(100), total_quantity_sold INT, total_revenue DECIMAL(18,2), avg_unit_price DECIMAL(18,2), order_count INT, refreshed_at DATETIME2 DEFAULT GETDATE())", 'mv_top_products')
run_sql(cursor, "CREATE TABLE semantic.mv_store_performance (store_key INT, store_id NVARCHAR(50), store_name NVARCHAR(200), region NVARCHAR(50), total_orders INT, total_revenue DECIMAL(18,2), avg_order_value DECIMAL(18,2), total_quantity INT, refreshed_at DATETIME2 DEFAULT GETDATE())", 'mv_store_performance')
run_sql(cursor, "CREATE TABLE semantic.mv_supplier_performance (supplier_key INT, supplier_id NVARCHAR(50), supplier_name NVARCHAR(200), total_purchases INT, total_spend DECIMAL(18,2), avg_delivery_days DECIMAL(10,2), on_time_pct DECIMAL(5,2), refreshed_at DATETIME2 DEFAULT GETDATE())", 'mv_supplier_performance')
run_sql(cursor, "CREATE TABLE semantic.mv_sales_vs_purchases (year INT, month INT, product_key INT, product_name NVARCHAR(200), category NVARCHAR(100), total_sold INT, total_purchased INT, revenue DECIMAL(18,2), cost DECIMAL(18,2), gross_margin DECIMAL(18,2), margin_pct DECIMAL(5,2), refreshed_at DATETIME2 DEFAULT GETDATE())", 'mv_sales_vs_purchases')
print('[OK] Semantic DDL complete')

# METADATA ********************
# META {}

# CELL ********************

run_sql(cursor, ' '.join([
    "INSERT INTO semantic.mv_daily_sales_summary (full_date,total_orders,total_quantity,gross_revenue,net_revenue,avg_order_value,refreshed_at)",
    "SELECT dd.full_date,COUNT(DISTINCT fo.order_key),SUM(fs.quantity),",
    "SUM(CAST(fs.quantity AS DECIMAL(18,2))*fs.unit_price),SUM(fs.net_amount),AVG(fo.total_amount),GETDATE()",
    "FROM silver.fact_sales fs JOIN silver.fact_orders fo ON fo.order_key=fs.order_key",
    "JOIN silver.dim_date dd ON dd.date_key=fs.sale_date_key GROUP BY dd.full_date"
]), 'mv_daily_sales_summary populated')

run_sql(cursor, ' '.join([
    "INSERT INTO semantic.mv_monthly_revenue (year,month,month_name,category,total_orders,total_quantity,net_revenue,refreshed_at)",
    "SELECT dd.year,dd.month,dd.month_name,dp.category,COUNT(DISTINCT fo.order_key),SUM(fs.quantity),SUM(fs.net_amount),GETDATE()",
    "FROM silver.fact_sales fs JOIN silver.fact_orders fo ON fo.order_key=fs.order_key",
    "JOIN silver.dim_date dd ON dd.date_key=fs.sale_date_key JOIN silver.dim_product dp ON dp.product_key=fs.product_key",
    "GROUP BY dd.year,dd.month,dd.month_name,dp.category"
]), 'mv_monthly_revenue populated')

run_sql(cursor, ' '.join([
    "INSERT INTO semantic.mv_customer_lifetime_value (customer_key,customer_id,customer_name,customer_segment,total_orders,total_spend,avg_order_value,first_purchase_date,last_purchase_date,ltv_tier,refreshed_at)",
    "SELECT dc.customer_key,dc.customer_id,dc.customer_name,dc.customer_segment,",
    "COUNT(DISTINCT fo.order_key),SUM(fo.total_amount),AVG(fo.total_amount),",
    "CAST(MIN(dd.full_date) AS DATE),CAST(MAX(dd.full_date) AS DATE),",
    "CASE WHEN SUM(fo.total_amount)>=5000 THEN 'Gold' WHEN SUM(fo.total_amount)>=2000 THEN 'Silver'",
    "     WHEN SUM(fo.total_amount)>=500 THEN 'Bronze' ELSE 'Standard' END,GETDATE()",
    "FROM silver.fact_orders fo JOIN silver.dim_customer dc ON dc.customer_key=fo.customer_key",
    "JOIN silver.dim_date dd ON dd.date_key=fo.order_date_key",
    "GROUP BY dc.customer_key,dc.customer_id,dc.customer_name,dc.customer_segment"
]), 'mv_customer_lifetime_value populated')

run_sql(cursor, ' '.join([
    "INSERT INTO semantic.mv_top_products (product_key,product_id,product_name,category,total_quantity_sold,total_revenue,avg_unit_price,order_count,refreshed_at)",
    "SELECT dp.product_key,dp.product_id,dp.product_name,dp.category,",
    "SUM(fs.quantity),SUM(fs.net_amount),AVG(fs.unit_price),COUNT(DISTINCT fs.order_key),GETDATE()",
    "FROM silver.fact_sales fs JOIN silver.dim_product dp ON dp.product_key=fs.product_key",
    "GROUP BY dp.product_key,dp.product_id,dp.product_name,dp.category"
]), 'mv_top_products populated')

run_sql(cursor, ' '.join([
    "INSERT INTO semantic.mv_store_performance (store_key,store_id,store_name,region,total_orders,total_revenue,avg_order_value,total_quantity,refreshed_at)",
    "SELECT ds.store_key,ds.store_id,ds.store_name,ds.region,COUNT(DISTINCT fo.order_key),",
    "SUM(fo.total_amount),AVG(fo.total_amount),COALESCE(SUM(fs.quantity),0),GETDATE()",
    "FROM silver.fact_orders fo JOIN silver.dim_store ds ON ds.store_key=fo.store_key",
    "LEFT JOIN silver.fact_sales fs ON fs.order_key=fo.order_key",
    "GROUP BY ds.store_key,ds.store_id,ds.store_name,ds.region"
]), 'mv_store_performance populated')

run_sql(cursor, ' '.join([
    "INSERT INTO semantic.mv_supplier_performance (supplier_key,supplier_id,supplier_name,total_purchases,total_spend,avg_delivery_days,on_time_pct,refreshed_at)",
    "SELECT dsp.supplier_key,dsp.supplier_id,dsp.supplier_name,COUNT(fp.purchase_key),SUM(fp.total_cost),",
    "AVG(CAST(fp.delivery_days AS DECIMAL(10,2))),",
    "ROUND(100.0*SUM(CASE WHEN fp.delivery_days<=14 AND fp.purchase_status='DELIVERED' THEN 1 ELSE 0 END)",
    "  /NULLIF(SUM(CASE WHEN fp.purchase_status='DELIVERED' THEN 1 ELSE 0 END),0),2),GETDATE()",
    "FROM silver.fact_purchases fp JOIN silver.dim_supplier dsp ON dsp.supplier_key=fp.supplier_key",
    "GROUP BY dsp.supplier_key,dsp.supplier_id,dsp.supplier_name"
]), 'mv_supplier_performance populated')

run_sql(cursor, ' '.join([
    "INSERT INTO semantic.mv_sales_vs_purchases (year,month,product_key,product_name,category,total_sold,total_purchased,revenue,cost,gross_margin,margin_pct,refreshed_at)",
    "SELECT COALESCE(s.yr,p.yr),COALESCE(s.mn,p.mn),dp.product_key,dp.product_name,dp.category,",
    "COALESCE(s.total_sold,0),COALESCE(p.total_purchased,0),COALESCE(s.revenue,0),COALESCE(p.cost,0),",
    "COALESCE(s.revenue,0)-COALESCE(p.cost,0),",
    "CASE WHEN COALESCE(s.revenue,0)>0 THEN ROUND((COALESCE(s.revenue,0)-COALESCE(p.cost,0))/s.revenue*100,2) ELSE 0 END,GETDATE()",
    "FROM (SELECT dd.year yr,dd.month mn,fs.product_key,SUM(fs.quantity) total_sold,SUM(fs.net_amount) revenue",
    "      FROM silver.fact_sales fs JOIN silver.dim_date dd ON dd.date_key=fs.sale_date_key GROUP BY dd.year,dd.month,fs.product_key) s",
    "FULL OUTER JOIN (SELECT dd.year yr,dd.month mn,fp.product_key,SUM(fp.quantity) total_purchased,SUM(fp.total_cost) cost",
    "      FROM silver.fact_purchases fp JOIN silver.dim_date dd ON dd.date_key=fp.purchase_date_key GROUP BY dd.year,dd.month,fp.product_key) p",
    "ON p.yr=s.yr AND p.mn=s.mn AND p.product_key=s.product_key",
    "JOIN silver.dim_product dp ON dp.product_key=COALESCE(s.product_key,p.product_key)"
]), 'mv_sales_vs_purchases populated')

# METADATA ********************
# META {}

# CELL ********************

print('--- Semantic Layer Counts ---')
for t in ['semantic.mv_daily_sales_summary','semantic.mv_monthly_revenue',
          'semantic.mv_customer_lifetime_value','semantic.mv_top_products',
          'semantic.mv_store_performance','semantic.mv_supplier_performance',
          'semantic.mv_sales_vs_purchases']:
    cursor.execute(f'SELECT COUNT(*) FROM {t}')
    print(f'  {t}: {cursor.fetchone()[0]:,}')
conn.close()
print('NB-03 done. Medallion architecture fully loaded.')

# METADATA ********************
# META {}
'@

$nb03 = New-FabricItemWithDef -Type "Notebook" -DisplayName "nb_03_semantic_views" `
    -Description "Medallion: Semantic layer — 7 materialized analytics tables" `
    -NotebookJsonContent $nb03Json

# ===========================================================================
# STEP 5 — Pipeline: pl_medallion_etl
# ===========================================================================
Write-Host "`n=== STEP 5: Pipeline — pl_medallion_etl ==="

$pipeline = New-FabricItemWithDef -Type "DataPipeline" -DisplayName "pl_medallion_etl" `
    -Description "Medallion ETL: Raw → Quality+Silver → Semantic (sequential)"

# Build pipeline definition with 3 sequential TridentNotebook activities
$pipelineDef = @{
    properties = @{
        activities  = @(
            @{
                name           = "01_RawDataSetup"
                type           = "TridentNotebook"
                dependsOn      = @()
                policy         = @{ timeout = "0.06:00:00"; retry = 1; retryIntervalInSeconds = 60 }
                typeProperties = @{ notebookId = $nb01.id; workspaceId = $WorkspaceId }
            },
            @{
                name           = "02_QualityAndSilver"
                type           = "TridentNotebook"
                dependsOn      = @( @{ activity = "01_RawDataSetup"; dependencyConditions = @("Succeeded") } )
                policy         = @{ timeout = "0.06:00:00"; retry = 1; retryIntervalInSeconds = 60 }
                typeProperties = @{ notebookId = $nb02.id; workspaceId = $WorkspaceId }
            },
            @{
                name           = "03_SemanticViews"
                type           = "TridentNotebook"
                dependsOn      = @( @{ activity = "02_QualityAndSilver"; dependencyConditions = @("Succeeded") } )
                policy         = @{ timeout = "0.06:00:00"; retry = 1; retryIntervalInSeconds = 60 }
                typeProperties = @{ notebookId = $nb03.id; workspaceId = $WorkspaceId }
            }
        )
        annotations = @()
        concurrency = 1
        parameters  = @{}
        variables   = @{}
    }
} | ConvertTo-Json -Depth 20 -Compress

$pipelineEncoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pipelineDef))

$updateBody = @{
    definition = @{
        parts = @( @{ path = "pipeline-content.json"; payload = $pipelineEncoded; payloadType = "InlineBase64" } )
    }
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Method Post `
    -Uri "$baseUrl/dataPipelines/$($pipeline.id)/updateDefinition" `
    -Headers $hdrs `
    -Body $updateBody | Out-Null

Write-Host "  [Pipeline] 'pl_medallion_etl' definition updated with 3 sequential activities."

# ===========================================================================
# SUMMARY
# ===========================================================================
Write-Host "`n=========================================="
Write-Host " MEDALLION DEPLOYMENT COMPLETE"
Write-Host "=========================================="
Write-Host " Workspace : $WorkspaceId"
Write-Host " Warehouse : copilot_dw_poc  (ID: $($wh.id))"
Write-Host " Notebook 1: nb_01_raw_data_setup      (ID: $($nb01.id))"
Write-Host " Notebook 2: nb_02_quality_silver       (ID: $($nb02.id))"
Write-Host " Notebook 3: nb_03_semantic_views       (ID: $($nb03.id))"
Write-Host " Pipeline  : pl_medallion_etl           (ID: $($pipeline.id))"
Write-Host "------------------------------------------"
Write-Host " Next step: run 'pl_medallion_etl' in the Fabric portal"
Write-Host " or trigger it via: POST /v1/workspaces/$WorkspaceId/dataPipelines/$($pipeline.id)/jobs/instances"
Write-Host "=========================================="
