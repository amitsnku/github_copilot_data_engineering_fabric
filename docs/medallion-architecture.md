# Medallion Architecture — Design & Data Model

This document describes the full architecture of the `ou_copilot_dw_poc` Fabric Warehouse,
including schema design, data model, quality rules, and semantic layer.

---

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    Fabric Warehouse: ou_copilot_dw_poc           │
│                                                                   │
│  ┌──────────┐    ┌──────────────────┐    ┌───────────────────┐  │
│  │  raw     │───▶│  silver          │───▶│  semantic         │  │
│  │  schema  │    │  schema          │    │  schema           │  │
│  │          │    │  (star schema)   │    │  (analytics views)│  │
│  └──────────┘    └──────────────────┘    └───────────────────┘  │
│       ▲                  ▲                                        │
│  nb_01_raw_data_setup  nb_02_quality_silver   nb_03_semantic_views│
│                                                                   │
│  ┌──────────┐                                                    │
│  │  audit   │  ← quality_log (12 checks per run)                │
│  │  schema  │                                                    │
│  └──────────┘                                                    │
└─────────────────────────────────────────────────────────────────┘
                          ▲
              pl_medallion_etl  (single pipeline)
```

---

## Schema: `raw` — Source Data As-Is

Three interrelated entities with ~100,000 total rows, including ~5% intentional quality issues.

### `raw.orders` — 30,000 rows

| Column | Type | Notes |
|---|---|---|
| `order_id` | NVARCHAR(50) | Primary key, format `ORD-NNNNNN` |
| `customer_id` | NVARCHAR(50) | 3% intentional NULLs |
| `store_id` | NVARCHAR(50) | References dim_store |
| `order_date` | DATE | 2% future dates (quality issue) |
| `order_status` | NVARCHAR(20) | `PENDING`, `PROCESSING`, `SHIPPED`, `DELIVERED`; 1% invalid values |
| `payment_method` | NVARCHAR(30) | `CARD`, `CASH`, `ONLINE`, `INVOICE` |
| `channel` | NVARCHAR(30) | `ONLINE`, `IN-STORE`, `PHONE`, `PARTNER` |
| `total_amount` | DECIMAL(18,2) | 2% negative values (quality issue) |

### `raw.sales` — 60,000 rows

| Column | Type | Notes |
|---|---|---|
| `sale_id` | NVARCHAR(50) | Primary key, format `SAL-NNNNNN` |
| `order_id` | NVARCHAR(50) | FK to raw.orders; 2% orphaned (quality issue) |
| `product_id` | NVARCHAR(50) | References dim_product |
| `store_id` | NVARCHAR(50) | References dim_store |
| `sale_date` | DATE | |
| `product_name` | NVARCHAR(200) | |
| `category` | NVARCHAR(100) | `Electronics`, `Accessories`, `Storage`, `Networking`, `Peripherals` |
| `quantity` | INT | |
| `unit_price` | DECIMAL(18,2) | |
| `discount_pct` | DECIMAL(5,2) | 0–30% |
| `net_amount` | DECIMAL(18,2) | Calculated: `quantity * unit_price * (1 - discount_pct/100)` |

### `raw.purchases` — 10,000 rows

| Column | Type | Notes |
|---|---|---|
| `purchase_id` | NVARCHAR(50) | Primary key, format `PUR-NNNNNN` |
| `supplier_id` | NVARCHAR(50) | References dim_supplier |
| `product_id` | NVARCHAR(50) | References dim_product |
| `store_id` | NVARCHAR(50) | References dim_store |
| `purchase_date` | DATE | |
| `supplier_name` | NVARCHAR(200) | |
| `quantity` | INT | |
| `unit_cost` | DECIMAL(18,2) | |
| `total_cost` | DECIMAL(18,2) | Calculated: `quantity * unit_cost` |
| `purchase_status` | NVARCHAR(20) | `ORDERED`, `IN_TRANSIT`, `DELIVERED`, `CANCELLED` |
| `expected_delivery` | DATE | |
| `actual_delivery` | DATE | NULL if not yet delivered |

---

## Schema: `audit` — Quality Log

### `audit.quality_log`

Populated by NB-02 on every pipeline run. 12 checks across all 3 raw tables.

| Column | Type | Description |
|---|---|---|
| `log_id` | INT IDENTITY | Auto-incrementing row ID |
| `run_id` | NVARCHAR(50) | UUID per notebook execution |
| `table_name` | NVARCHAR(100) | e.g. `raw.orders` |
| `check_name` | NVARCHAR(200) | e.g. `NULL customer_id` |
| `check_type` | NVARCHAR(50) | `Completeness`, `Validity`, `Uniqueness`, `Ref. Integrity` |
| `total_records` | INT | Total rows in table |
| `failed_records` | INT | Rows that failed this check |
| `pass_rate` | DECIMAL(8,4) | `(total - failed) / total * 100` |
| `status` | NVARCHAR(10) | `PASS` (0 failures), `WARN` (<10%), `FAIL` (≥10%) |
| `logged_at` | DATETIME2 | Timestamp of check |

**12 Quality Checks:**

| Table | Check | Type |
|---|---|---|
| raw.orders | NULL customer_id | Completeness |
| raw.orders | Negative total_amount | Validity |
| raw.orders | Future order_date | Validity |
| raw.orders | Invalid order_status | Validity |
| raw.orders | Duplicate order_id | Uniqueness |
| raw.sales | NULL order_id | Completeness |
| raw.sales | Orphaned order_id | Referential Integrity |
| raw.sales | Zero/negative quantity | Validity |
| raw.sales | Negative net_amount | Validity |
| raw.purchases | NULL supplier_id | Completeness |
| raw.purchases | Invalid purchase_status | Validity |
| raw.purchases | Negative total_cost | Validity |

---

## Schema: `silver` — Star Schema (Cleansed)

Only **quality-passing rows** from raw are loaded. Failed rows are excluded, not deleted from raw.

### Dimension Tables

| Table | Grain | Key Column | Source |
|---|---|---|---|
| `dim_date` | One row per calendar day (730 days) | `date_key` INT (YYYYMMDD) | Generated via CTE |
| `dim_customer` | One row per unique customer | `customer_key` IDENTITY | raw.orders (filtered) |
| `dim_product` | One row per unique product | `product_key` IDENTITY | raw.sales (filtered) |
| `dim_supplier` | One row per unique supplier | `supplier_key` IDENTITY | raw.purchases (filtered) |
| `dim_store` | One row per unique store | `store_key` IDENTITY | raw.orders + raw.sales |

`dim_customer` uses **Type 2 SCD** columns (`valid_from`, `valid_to`, `is_current`).

### Fact Tables

| Table | Grain | Foreign Keys |
|---|---|---|
| `fact_orders` | One row per order | customer_key, store_key, order_date_key |
| `fact_sales` | One row per line item | order_key, product_key, store_key, sale_date_key |
| `fact_purchases` | One row per purchase | supplier_key, product_key, store_key, purchase_date_key |

**Star Schema Diagram:**

```
dim_date ◄──── fact_orders ────► dim_customer
                    │
                    ▼
dim_date ◄──── fact_sales  ────► dim_product
                    │
                    └───────────► dim_store

dim_date ◄──── fact_purchases ──► dim_supplier
                    │
                    └───────────► dim_product
                    └───────────► dim_store
```

---

## Schema: `semantic` — Materialized Analytics Tables

7 pre-aggregated tables, refreshed on every pipeline run. Ready for Power BI / dashboards.

| Table | Description | Key Metrics |
|---|---|---|
| `mv_daily_sales_summary` | One row per day | total_orders, total_quantity, gross_revenue, net_revenue, avg_order_value |
| `mv_monthly_revenue` | One row per month × category | total_orders, total_quantity, net_revenue |
| `mv_customer_lifetime_value` | One row per customer | total_orders, total_spend, avg_order_value, ltv_tier (Gold/Silver/Bronze/Standard) |
| `mv_top_products` | One row per product | total_quantity_sold, total_revenue, avg_unit_price, order_count |
| `mv_store_performance` | One row per store | total_orders, total_revenue, avg_order_value, total_quantity |
| `mv_supplier_performance` | One row per supplier | total_purchases, total_spend, avg_delivery_days, on_time_pct |
| `mv_sales_vs_purchases` | One row per month × product | total_sold, total_purchased, revenue, cost, gross_margin, margin_pct |

**LTV Tier rules:**

| Tier | Total Spend |
|---|---|
| Gold | ≥ £5,000 |
| Silver | ≥ £2,000 |
| Bronze | ≥ £500 |
| Standard | < £500 |

---

## Pipeline: `pl_medallion_etl`

Single pipeline with 3 sequential `TridentNotebook` activities:

```
[nb_01_raw_data_setup] ──► [nb_02_quality_silver] ──► [nb_03_semantic_views]
   ~2-3 min                    ~3-5 min                   ~1-2 min
```

Each activity has `dependsOn` set to the previous, so the pipeline stops on failure.

---

## Data Generation Approach

Raw data is generated entirely in T-SQL using:
- **Recursive CTEs** (`L0 → L4` cross joins) to produce large row sets without loops
- `ABS(CHECKSUM(NEWID())) % N` for per-row random integers
- `CHOOSE(n, v1, v2, ...)` for random categorical values
- `DATEADD(DAY, -ABS(CHECKSUM(NEWID()))%730, GETDATE())` for random dates within 2 years
- `TOP N` to limit row counts precisely
