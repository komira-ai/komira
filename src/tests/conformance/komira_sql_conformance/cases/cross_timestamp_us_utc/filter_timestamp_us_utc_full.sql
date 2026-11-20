-- order: rows
-- filter over a TIMESTAMPTZ column, full rows
SELECT k, g, v FROM t_full WHERE v > TIMESTAMPTZ '2024-01-01 03:30:15.123456+00'
