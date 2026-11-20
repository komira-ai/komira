-- order: rows
-- join anti over a TIMESTAMP_MS column, full rows
SELECT k, g, v FROM t_full WHERE k NOT IN (SELECT g FROM t_full)
