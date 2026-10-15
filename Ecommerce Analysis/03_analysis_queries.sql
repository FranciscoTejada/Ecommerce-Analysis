-- =====================================================================
-- 03_analysis_queries.sql
-- E-commerce analysis 2025: queries for the manager's three questions.
--
-- Run after 01_create_tables.sql and after importing the five CSV files.
--
-- Metric definitions used throughout:
--   Sale              = any order that was not cancelled
--   Net revenue       = amount after discounts, before tax and shipping
--   ROAS              = net revenue / advertising spend
--   Profit after ads  = gross profit - advertising spend
--   New customer      = first-time visitor (not always their first purchase)
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. Sanity check: row counts
--    Expected: 84 / 2555 / 2555 / 2908 / 480195
-- ---------------------------------------------------------------------
SELECT 'channel_performance'   AS table_name, COUNT(*) AS row_count FROM channel_performance
UNION ALL SELECT 'daily_traffic',         COUNT(*) FROM daily_traffic
UNION ALL SELECT 'daily_orders',          COUNT(*) FROM daily_orders
UNION ALL SELECT 'order_financials',      COUNT(*) FROM order_financials
UNION ALL SELECT 'web_navigation_events', COUNT(*) FROM web_navigation_events;


-- =====================================================================
-- QUESTION 1: Have sales declined?
-- =====================================================================

-- 1a. Net revenue and orders by month, with change vs. the previous month
WITH monthly AS (
    SELECT DATE_TRUNC('month', order_date)::date AS month,
           COUNT(*)                              AS orders,
           ROUND(SUM(net_revenue), 2)            AS net_revenue
    FROM order_financials
    WHERE order_status <> 'cancelled'
    GROUP BY 1
)
SELECT month,
       orders,
       net_revenue,
       ROUND(100.0 * (net_revenue - LAG(net_revenue) OVER (ORDER BY month))
             / LAG(net_revenue) OVER (ORDER BY month), 1) AS change_vs_previous_month_pct
FROM monthly
ORDER BY month;


-- =====================================================================
-- QUESTION 2: Which marketing channels are worth the investment?
-- =====================================================================

-- 2a. Profitability by paid channel
--     ROAS is computed from totals (not by averaging monthly ratios).
--     Channels without advertising spend (organic_search, direct, referral)
--     are excluded because they have no ROAS.
WITH sales AS (
    SELECT channel,
           SUM(net_revenue)  AS net_revenue,
           SUM(gross_profit) AS gross_profit
    FROM order_financials
    WHERE order_status <> 'cancelled'
    GROUP BY channel
),
spend AS (
    SELECT channel,
           SUM(spend) AS investment
    FROM channel_performance
    GROUP BY channel
)
SELECT s.channel,
       s.investment,
       v.net_revenue,
       ROUND(v.net_revenue / NULLIF(s.investment, 0), 2) AS roas,
       ROUND(v.gross_profit - s.investment, 2)            AS profit_after_ads
FROM spend s
JOIN sales v USING (channel)
WHERE s.investment > 0
ORDER BY roas DESC;


-- 2b. New vs. returning customers by channel
SELECT channel,
       SUM(orders)                    AS orders,
       SUM(new_customer_orders)       AS new_customer_orders,
       SUM(returning_customer_orders) AS returning_customer_orders,
       ROUND(100.0 * SUM(new_customer_orders) / NULLIF(SUM(orders), 0), 1) AS new_customer_pct
FROM daily_orders
GROUP BY channel
ORDER BY new_customer_pct DESC;


-- =====================================================================
-- QUESTION 3: Where do customers drop off, and does it change by device?
-- =====================================================================

-- 3a. Funnel by device: distinct sessions reaching each stage,
--     and the share that advances from one stage to the next
WITH funnel AS (
    SELECT device,
           COUNT(DISTINCT session_id) FILTER (WHERE event_type = 'page_view')      AS sessions,
           COUNT(DISTINCT session_id) FILTER (WHERE event_type = 'view_item')      AS viewed_product,
           COUNT(DISTINCT session_id) FILTER (WHERE event_type = 'add_to_cart')    AS added_to_cart,
           COUNT(DISTINCT session_id) FILTER (WHERE event_type = 'begin_checkout') AS started_checkout,
           COUNT(DISTINCT session_id) FILTER (WHERE event_type = 'purchase')       AS purchased
    FROM web_navigation_events
    GROUP BY device
)
SELECT device,
       sessions, viewed_product, added_to_cart, started_checkout, purchased,
       ROUND(100.0 * viewed_product   / sessions,         1) AS pct_view_product,
       ROUND(100.0 * added_to_cart    / viewed_product,   1) AS pct_add_to_cart,
       ROUND(100.0 * started_checkout / added_to_cart,    1) AS pct_start_checkout,
       ROUND(100.0 * purchased        / started_checkout, 1) AS pct_purchase,
       ROUND(100.0 * purchased        / sessions,         2) AS overall_conversion_pct
FROM funnel
ORDER BY sessions DESC;


-- 3b. Size of the mobile opportunity: extra orders if mobile converted
--     from checkout to purchase at the same rate as desktop (estimate)
WITH checkout AS (
    SELECT device,
           COUNT(DISTINCT session_id) FILTER (WHERE event_type = 'begin_checkout') AS started_checkout,
           COUNT(DISTINCT session_id) FILTER (WHERE event_type = 'purchase')       AS purchased
    FROM web_navigation_events
    GROUP BY device
)
SELECT m.started_checkout                                                 AS mobile_checkouts,
       m.purchased                                                        AS mobile_purchases,
       ROUND(m.started_checkout * d.purchased::numeric / d.started_checkout) AS purchases_at_desktop_rate,
       ROUND(m.started_checkout * d.purchased::numeric / d.started_checkout) - m.purchased AS extra_orders
FROM checkout m, checkout d
WHERE m.device = 'mobile' AND d.device = 'desktop';
