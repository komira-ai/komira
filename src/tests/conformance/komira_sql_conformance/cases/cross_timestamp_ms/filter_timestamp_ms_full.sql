-- order: rows
-- filter over a TIMESTAMP_MS column, full rows
SELECT k, g, v FROM t_full WHERE v > TIMESTAMP '2024-01-01 03:30:15.123000'
