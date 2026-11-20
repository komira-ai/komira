-- order: rows
-- filter project over a TIMESTAMP_MS column, full rows
SELECT v FROM t_full WHERE v > TIMESTAMP '2024-01-01 03:30:15.123000'
