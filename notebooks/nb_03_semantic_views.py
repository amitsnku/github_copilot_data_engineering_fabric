# Fabric notebook source

# MARKDOWN ********************
# ## NB-03 | Semantic Layer - 7 Materialized View Tables
# 1. mv_daily_sales_summary  2. mv_monthly_revenue  3. mv_customer_lifetime_value
# 4. mv_top_products  5. mv_store_performance  6. mv_supplier_performance  7. mv_sales_vs_purchases

# CELL ********************

import pyodbc, struct
from notebookutils import mssparkutils

WAREHOUSE = 'copilot_dw_poc'
ws_id  = ''  # Fabric workspace ID # Fabric workspace ID
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
