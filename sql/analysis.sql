
-- STEP 0. Проверка качества: line_amount vs amount_total

SELECT t.transaction_id, t.amount_total, SUM(i.line_amount) AS sum_items,
       t.amount_total - SUM(i.line_amount) AS diff
FROM transactions t
JOIN transaction_items i ON i.transaction_id = t.transaction_id
GROUP BY t.transaction_id
HAVING ABS(diff) > 0.5
LIMIT 20;

SELECT status, COUNT(*) FROM transactions GROUP BY status;
SELECT transaction_id, COUNT(*) FROM transactions GROUP BY transaction_id HAVING COUNT(*) > 1;


-- STEP 1. Дневные метрики по магазину (только completed)

DROP VIEW IF EXISTS daily_store;
CREATE VIEW daily_store AS
SELECT
    store_id,
    DATE(opened_at) AS dt,
    SUM(amount_total)              AS revenue,
    COUNT(*)                        AS traffic,
    SUM(amount_total) * 1.0 / COUNT(*) AS avg_check
FROM transactions
WHERE status = 'completed'
GROUP BY store_id, DATE(opened_at);


-- STEP 2. Разметка period (pre/post) + группа + пара

DROP VIEW IF EXISTS daily_store_labeled;
CREATE VIEW daily_store_labeled AS
SELECT
    d.*,
    s.experiment_group,
    s.pair_id,
    CASE WHEN d.dt < '2025-07-14' THEN 'pre' ELSE 'post' END AS period
FROM daily_store d
JOIN stores s ON s.store_id = d.store_id;


-- STEP 3. Среднее по магазину за период

DROP VIEW IF EXISTS store_period;
CREATE VIEW store_period AS
SELECT
    store_id, experiment_group, pair_id, period,
    AVG(revenue)   AS avg_revenue,
    AVG(traffic)   AS avg_traffic,
    AVG(avg_check) AS avg_avg_check
FROM daily_store_labeled
GROUP BY store_id, experiment_group, pair_id, period;


-- STEP 4. Пара -> DiD по каждой метрике (30 строк = 30 пар)

DROP VIEW IF EXISTS pair_did;
CREATE VIEW pair_did AS
SELECT
    pair_id,
    MAX(CASE WHEN experiment_group='test'    AND period='pre'  THEN avg_revenue END) AS test_pre_rev,
    MAX(CASE WHEN experiment_group='control' AND period='pre'  THEN avg_revenue END) AS ctrl_pre_rev,
    MAX(CASE WHEN experiment_group='test'    AND period='post' THEN avg_revenue END) AS test_post_rev,
    MAX(CASE WHEN experiment_group='control' AND period='post' THEN avg_revenue END) AS ctrl_post_rev,

    MAX(CASE WHEN experiment_group='test'    AND period='pre'  THEN avg_traffic END) AS test_pre_traf,
    MAX(CASE WHEN experiment_group='control' AND period='pre'  THEN avg_traffic END) AS ctrl_pre_traf,
    MAX(CASE WHEN experiment_group='test'    AND period='post' THEN avg_traffic END) AS test_post_traf,
    MAX(CASE WHEN experiment_group='control' AND period='post' THEN avg_traffic END) AS ctrl_post_traf,

    MAX(CASE WHEN experiment_group='test'    AND period='pre'  THEN avg_avg_check END) AS test_pre_chk,
    MAX(CASE WHEN experiment_group='control' AND period='pre'  THEN avg_avg_check END) AS ctrl_pre_chk,
    MAX(CASE WHEN experiment_group='test'    AND period='post' THEN avg_avg_check END) AS test_post_chk,
    MAX(CASE WHEN experiment_group='control' AND period='post' THEN avg_avg_check END) AS ctrl_post_chk
FROM store_period
GROUP BY pair_id;

-- Таблица DiD по 30 парам (все три метрики сразу):
SELECT
    pair_id,
    (test_post_rev - ctrl_post_rev) - (test_pre_rev - ctrl_pre_rev)   AS did_revenue,
    (test_post_traf - ctrl_post_traf) - (test_pre_traf - ctrl_pre_traf) AS did_traffic,
    (test_post_chk - ctrl_post_chk) - (test_pre_chk - ctrl_pre_chk)   AS did_avg_check
FROM pair_did;


-- STEP 4b. Статистика по 30 парам — по очереди для каждой метрики

-- REVENUE:
WITH did AS (
    SELECT pair_id, (test_post_rev - ctrl_post_rev) - (test_pre_rev - ctrl_pre_rev) AS did_metric
    FROM pair_did
),
stats AS (SELECT AVG(did_metric) AS mean_did, COUNT(*) AS n FROM did)
SELECT s.mean_did, s.n,
       SQRT(SUM((d.did_metric - s.mean_did)*(d.did_metric - s.mean_did)) / (s.n - 1)) AS stdev
FROM did d, stats s GROUP BY s.mean_did, s.n;

-- TRAFFIC
WITH did AS (
    SELECT pair_id, (test_post_traf - ctrl_post_traf) - (test_pre_traf - ctrl_pre_traf) AS did_metric
    FROM pair_did
),
stats AS (SELECT AVG(did_metric) AS mean_did, COUNT(*) AS n FROM did)
SELECT s.mean_did, s.n,
       SQRT(SUM((d.did_metric - s.mean_did)*(d.did_metric - s.mean_did)) / (s.n - 1)) AS stdev
FROM did d, stats s GROUP BY s.mean_did, s.n;

-- AVG_CHECK:
WITH did AS (
    SELECT pair_id, (test_post_chk - ctrl_post_chk) - (test_pre_chk - ctrl_pre_chk) AS did_metric
    FROM pair_did
),
stats AS (SELECT AVG(did_metric) AS mean_did, COUNT(*) AS n FROM did)
SELECT s.mean_did, s.n,
       SQRT(SUM((d.did_metric - s.mean_did)*(d.did_metric - s.mean_did)) / (s.n - 1)) AS stdev
FROM did d, stats s GROUP BY s.mean_did, s.n;


-- STEP 5. ROBUSTNESS CHECK: DiD по revenue без недели жары
-- (21-27 июля исключены)

DROP VIEW IF EXISTS daily_store_noheat;
CREATE VIEW daily_store_noheat AS
SELECT
    store_id, DATE(opened_at) AS dt,
    SUM(amount_total) AS revenue,
    COUNT(*) AS traffic,
    SUM(amount_total) * 1.0 / COUNT(*) AS avg_check
FROM transactions
WHERE status = 'completed'
  AND DATE(opened_at) NOT BETWEEN '2025-07-21' AND '2025-07-27'
GROUP BY store_id, DATE(opened_at);

DROP VIEW IF EXISTS daily_store_labeled_noheat;
CREATE VIEW daily_store_labeled_noheat AS
SELECT d.*, s.experiment_group, s.pair_id,
       CASE WHEN d.dt < '2025-07-14' THEN 'pre' ELSE 'post' END AS period
FROM daily_store_noheat d
JOIN stores s ON s.store_id = d.store_id;

DROP VIEW IF EXISTS store_period_noheat;
CREATE VIEW store_period_noheat AS
SELECT store_id, experiment_group, pair_id, period,
       AVG(revenue) AS avg_revenue, AVG(traffic) AS avg_traffic, AVG(avg_check) AS avg_avg_check
FROM daily_store_labeled_noheat
GROUP BY store_id, experiment_group, pair_id, period;

DROP VIEW IF EXISTS pair_did_noheat;
CREATE VIEW pair_did_noheat AS
SELECT pair_id,
    MAX(CASE WHEN experiment_group='test'    AND period='pre'  THEN avg_revenue END) AS test_pre_rev,
    MAX(CASE WHEN experiment_group='control' AND period='pre'  THEN avg_revenue END) AS ctrl_pre_rev,
    MAX(CASE WHEN experiment_group='test'    AND period='post' THEN avg_revenue END) AS test_post_rev,
    MAX(CASE WHEN experiment_group='control' AND period='post' THEN avg_revenue END) AS ctrl_post_rev
FROM store_period_noheat
GROUP BY pair_id;


SELECT name FROM sqlite_master WHERE type='view' AND name='pair_did_noheat';

-- Итоговая статистика revenue БЕЗ недели жары — сравни с основным +2280:
WITH did AS (
    SELECT pair_id, (test_post_rev - ctrl_post_rev) - (test_pre_rev - ctrl_pre_rev) AS did_metric
    FROM pair_did_noheat
),
stats AS (SELECT AVG(did_metric) AS mean_did, COUNT(*) AS n FROM did)
SELECT s.mean_did, s.n,
       SQRT(SUM((d.did_metric - s.mean_did)*(d.did_metric - s.mean_did)) / (s.n - 1)) AS stdev
FROM did d, stats s GROUP BY s.mean_did, s.n;


-- STEP 6. Энергетик P0001 — окна pre / promo+жара / promo без жары

DROP VIEW IF EXISTS energy_windows;
CREATE VIEW energy_windows AS
SELECT
    i.product_id, i.quantity, p.category_name,
    CASE
        WHEN DATE(t.opened_at) < '2025-07-21' THEN 'pre_promo'
        WHEN DATE(t.opened_at) <= '2025-07-27' THEN 'promo_and_heat'
        WHEN DATE(t.opened_at) <= '2025-08-03' THEN 'promo_no_heat'
        ELSE 'post_promo'
    END AS window
FROM transaction_items i
JOIN transactions t ON t.transaction_id = i.transaction_id
JOIN products p ON p.product_id = i.product_id
WHERE t.status = 'completed';


SELECT window, SUM(quantity) AS units_sold
FROM energy_windows
WHERE product_id = 'P0001'
GROUP BY window
ORDER BY CASE window
    WHEN 'pre_promo' THEN 1 WHEN 'promo_and_heat' THEN 2
    WHEN 'promo_no_heat' THEN 3 ELSE 4 END;


WITH window_days AS (
    SELECT
        CASE
            WHEN DATE(t.opened_at) < '2025-07-21' THEN 'pre_promo'
            WHEN DATE(t.opened_at) <= '2025-07-27' THEN 'promo_and_heat'
            WHEN DATE(t.opened_at) <= '2025-08-03' THEN 'promo_no_heat'
            ELSE 'post_promo'
        END AS window,
        DATE(t.opened_at) AS dt
    FROM transactions t
    WHERE t.status = 'completed'
    GROUP BY window, dt
),
days_count AS (
    SELECT window, COUNT(*) AS n_days FROM window_days GROUP BY window
)
SELECT
    w.window,
    d.n_days,
    ROUND(SUM(CASE WHEN w.product_id='P0001' THEN w.quantity ELSE 0 END) * 1.0 / d.n_days, 1) AS energy_per_day,
    ROUND(SUM(CASE WHEN w.product_id!='P0001' THEN w.quantity ELSE 0 END) * 1.0 / d.n_days, 1) AS rest_category_per_day
FROM energy_windows w
JOIN days_count d ON d.window = w.window
WHERE w.category_name = (SELECT category_name FROM products WHERE product_id='P0001')
GROUP BY w.window, d.n_days
ORDER BY CASE w.window
    WHEN 'pre_promo' THEN 1 WHEN 'promo_and_heat' THEN 2
    WHEN 'promo_no_heat' THEN 3 ELSE 4 END;

-- Доля энергетика в категории по окнам (доля не зависит от длины окна,
-- делить на дни не нужно):
SELECT
    w.window,
    SUM(CASE WHEN w.product_id='P0001' THEN w.quantity ELSE 0 END) AS energy_units,
    SUM(w.quantity) AS category_units,
    ROUND(100.0 * SUM(CASE WHEN w.product_id='P0001' THEN w.quantity ELSE 0 END)
          / SUM(w.quantity), 1) AS energy_share_pct
FROM energy_windows w
WHERE w.category_name = (SELECT category_name FROM products WHERE product_id='P0001')
GROUP BY w.window
ORDER BY CASE w.window
    WHEN 'pre_promo' THEN 1 WHEN 'promo_and_heat' THEN 2
    WHEN 'promo_no_heat' THEN 3 ELSE 4 END;


-- STEP 7 (для графика в Superset). Дневная выручка test vs control
-- по всему периоду — для проверки parallel trends и визуализации

SELECT
    dt,
    experiment_group,
    AVG(revenue) AS avg_revenue_per_store
FROM daily_store_labeled
GROUP BY dt, experiment_group
ORDER BY dt;
