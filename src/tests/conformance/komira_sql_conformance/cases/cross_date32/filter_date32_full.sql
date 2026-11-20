-- order: rows
-- filter over a DATE column, full rows
SELECT k, g, v FROM t_full WHERE v > DATE '2024-01-03'
