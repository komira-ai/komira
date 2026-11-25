-- A filter and a grouped aggregate over a table registered from memory
-- (lj_orders_mem, the rows of lj_orders through register_arrow): the
-- resident table answers as DuckDB answers over the same rows.
SELECT o_cust, count(*) AS n, max(o_id) AS top FROM lj_orders_mem WHERE o_comment = 'plain' GROUP BY o_cust ORDER BY o_cust ASC NULLS LAST
