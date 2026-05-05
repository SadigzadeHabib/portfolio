
USE olist;

/* ===========================================================
   CLEANING CUSTOMERS TABLE
   What I do here:
   1) Keep only one row per unique customer (the smallest / earliest id).
   2) Save it into a new table called customers_cleaned.
   3) Add some helpful indexes so future joins and lookups
      (by state, city, or unique_id) run much faster.

   End result: a nice, tidy "customer dimension" table
   =========================================================== */
DROP TABLE IF EXISTS customer_cleaned;

CREATE TABLE customer_cleaned AS
SELECT c.*
FROM order_customer_dataset c
JOIN (
  SELECT customer_unique_id, MIN(customer_id) AS keep_id
  FROM order_customer_dataset
  GROUP BY customer_unique_id
) k
  ON c.customer_unique_id = k.customer_unique_id
 AND c.customer_id        = k.keep_id;

ALTER TABLE customer_cleaned
  ADD PRIMARY KEY (customer_id),
  ADD INDEX idx_cc_unique (customer_unique_id),
  ADD INDEX idx_cc_state  (customer_state),
  ADD INDEX idx_cc_city   (customer_city);
  
  
  
/* ===========================================================
   CLEANING ORDERS TABLE
   -----------------------------------------------------------
   What I do here:
   1) Keep the key columns we actually use.
   2) Convert timestamps to DATE for simpler grouping/joining.
   3) Add indexes for faster filters and joins.

   End result: tidy orders_cleaned ready for joins.
   =========================================================== */
DROP TABLE IF EXISTS order_cleaned;

CREATE TABLE order_cleaned AS
SELECT
  o.order_id,
  o.customer_id,
  o.order_status,
  DATE(o.order_purchase_timestamp)      AS purchase_date,
  DATE(o.order_approved_at)             AS approved_date,
  DATE(o.order_delivered_carrier_date)  AS delivered_carrier_date,
  DATE(o.order_delivered_customer_date) AS delivered_date,
  DATE(o.order_estimated_delivery_date) AS estimated_date
FROM order_dataset o;

ALTER TABLE order_cleaned
  ADD PRIMARY KEY (order_id),
  ADD INDEX idx_oc_customer (customer_id),
  ADD INDEX idx_oc_purchase (purchase_date);


/* ===========================================================
   CLEANING ORDER ITEMS TABLE
   -----------------------------------------------------------

   What I do here:
   1) Keep order_id / order_item_id and money fields.
   2) Ensure non-negative price & freight.
   3) Add a composite PK and useful index.

   End result: order_items_cleaned that rolls up nicely.
   =========================================================== */

DROP TABLE IF EXISTS order_item_cleaned;

CREATE TABLE order_item_cleaned AS
SELECT
  oi.order_id,
  oi.order_item_id,
  GREATEST(oi.price, 0)         AS price,
  GREATEST(oi.freight_value, 0) AS freight_value
FROM order_items_dataset oi;

ALTER TABLE order_item_cleaned
  ADD PRIMARY KEY (order_id, order_item_id),
  ADD INDEX idx_oi_order (order_id);


/* ===========================================================
   BUILDING FACT_ORDERS_MIN TABLE
   -----------------------------------------------------------
   What I do here:
   1) First, roll up order_items into totals (items_value,
      freight_value, item_count) by order_id.
   2) Join orders_cleaned + customers_cleaned + rolled-up items.
   3) Calculate extra metrics on the fly:
      - days_to_deliver  = actual delivery - purchase date
      - delay_days       = actual delivery - estimated delivery
      - gross_order_value = items + freight
   4) Store the result as fact_orders_min with indexes for
      faster filtering by date and state.

   End result: single “fact” table ready for KPIs, dashboards
   =========================================================== */

DROP TABLE IF EXISTS fact_orders_min;

CREATE TABLE fact_orders_min AS
WITH items AS (
  SELECT
    order_id,
    SUM(price)         AS items_value,
    SUM(freight_value) AS freight_value,
    COUNT(*)           AS item_count
  FROM order_item_cleaned
  GROUP BY order_id
)
SELECT
  o.order_id,
  o.customer_id,
  c.customer_unique_id,
  c.customer_city,
  c.customer_state,
  o.order_status,
  o.purchase_date,
  o.delivered_date,
  o.estimated_date,
  TIMESTAMPDIFF(DAY, o.purchase_date, o.delivered_date) AS days_to_deliver,
  TIMESTAMPDIFF(DAY, o.estimated_date, o.delivered_date) AS delay_days,
  i.items_value,
  i.freight_value,
  (i.items_value + i.freight_value) AS gross_order_value,
  i.item_count
FROM order_cleaned o
LEFT JOIN customer_cleaned c ON o.customer_id = c.customer_id
LEFT JOIN items i             ON o.order_id = i.order_id;

ALTER TABLE fact_orders_min
  ADD PRIMARY KEY (order_id),
  ADD INDEX idx_fom_date  (purchase_date),
  ADD INDEX idx_fom_state (customer_state);
  
  
  

/* ===========================================================
   CREATING VIEW: v_monthly_kpis
   -----------------------------------------------------------
   What this view gives us:
   - month_start       = first day of the month (for grouping)
   - orders            = total number of orders
   - revenue           = total gross order value
   - avg_order_value   = average order value (AOV)
   - avg_days_to_deliver = average delivery speed
   - late_rate         = share of orders delivered later
                         than their estimated delivery date

   End result: quick, ready-to-use dataset for plotting
   revenue trends, order counts, delivery performance,
   and late delivery rates month by month.
   =========================================================== */

DROP VIEW IF EXISTS v_monthly_kpis;

CREATE VIEW v_monthly_kpis AS
SELECT
  DATE_FORMAT(purchase_date, '%Y-%m-01') AS month_start,
  COUNT(*)                                AS orders,
  SUM(gross_order_value)                  AS revenue,
  AVG(gross_order_value)                  AS avg_order_value,
  AVG(days_to_deliver)                    AS avg_days_to_deliver,
  AVG(CASE WHEN delay_days > 0 THEN 1 ELSE 0 END) AS late_rate
FROM fact_orders_min
WHERE purchase_date IS NOT NULL
GROUP BY month_start;

/* ===========================================================
   CREATING VIEW: v_top_state_by_month
   -----------------------------------------------------------
   What this view does:
   1) Groups orders by state and month, sums up revenue.
   2) Ranks states within each month by revenue.
   3) Keeps only the #1 state (highest revenue that month).

   End result: simple month → top_state mapping,
   showing the leading state and its revenue contribution.
   =========================================================== */

DROP VIEW IF EXISTS v_top_state_by_month;

CREATE VIEW v_top_state_by_month AS
WITH s AS (
  SELECT
    DATE_FORMAT(purchase_date, '%Y-%m-01') AS month_start,
    customer_state,
    SUM(gross_order_value) AS revenue_state
  FROM fact_orders_min
  GROUP BY month_start, customer_state
),
r AS (
  SELECT
    s.*,
    ROW_NUMBER() OVER (PARTITION BY month_start ORDER BY revenue_state DESC) AS rn
  FROM s
)
SELECT month_start, customer_state, revenue_state
FROM r
WHERE rn = 1;

/* ===========================================================
   CREATING VIEW: v_city_revenue
   -----------------------------------------------------------
   What this view does:
   - Groups orders by state and city.
   - Aggregates total revenue and order count.

   End result: geo-level dataset (city + state) that
   powers bar charts, maps, and city-level analysis.
   =========================================================== */

DROP VIEW IF EXISTS v_city_revenue;

CREATE VIEW v_city_revenue AS
SELECT
  customer_state,
  customer_city,
  SUM(gross_order_value) AS revenue,
  COUNT(*)               AS orders
FROM fact_orders_min
GROUP BY customer_state, customer_city;


/* ===========================================================
   CREATING VIEW: v_recent_orders
   -----------------------------------------------------------

   What this view does:
   - Selects all columns from fact_orders_min.
   - Filters to only orders in the last 90 days.

   End result: lightweight slice of the fact table
   focusing on fresh data for ongoing monitoring.
   =========================================================== */

DROP VIEW IF EXISTS v_recent_orders;

CREATE VIEW v_recent_orders AS
SELECT *
FROM fact_orders_min
WHERE purchase_date >= DATE_SUB(CURDATE(), INTERVAL 90 DAY);

  
