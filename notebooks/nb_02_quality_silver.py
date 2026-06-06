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
ws_id  = ''  # Fabric workspace ID  # Fabric workspace ID
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
