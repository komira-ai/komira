-- order: rows
-- filter project over a TIMESTAMPTZ column, full rows
SELECT v FROM t_full WHERE v > TIMESTAMPTZ '2024-01-01 03:30:15.123456+00'
