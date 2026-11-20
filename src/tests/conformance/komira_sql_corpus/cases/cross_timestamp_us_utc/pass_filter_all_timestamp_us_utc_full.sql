-- order: rows
-- pass filter all over a TIMESTAMPTZ column, full rows
SELECT k, g, v FROM t_full WHERE k > 2
