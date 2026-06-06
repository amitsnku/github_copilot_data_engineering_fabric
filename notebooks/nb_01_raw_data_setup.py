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
