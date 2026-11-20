-- order: rows
-- pass filter all over a DECIMAL(12,2) column, full rows
SELECT k, g, v FROM t_full WHERE k > 2
