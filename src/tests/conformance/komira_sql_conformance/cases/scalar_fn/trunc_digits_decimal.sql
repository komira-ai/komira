-- order: rows
SELECT k, trunc(CAST(d AS DECIMAL(12,4)) - CAST(0.0789 AS DECIMAL(12,4)), 1) AS t1, trunc(CAST(d AS DECIMAL(12,4)) - CAST(5.5 AS DECIMAL(12,4)), -1) AS tm1, trunc(CAST(d AS DECIMAL(12,4)), -12) AS tm12 FROM T
