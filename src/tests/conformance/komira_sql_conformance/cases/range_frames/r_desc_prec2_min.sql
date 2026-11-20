-- order: rows
-- descending key: PRECEDING measures toward larger key values (a trailing value window of width 2 on the key)
SELECT k, min(v) OVER (PARTITION BY g ORDER BY o DESC RANGE BETWEEN 2 PRECEDING AND CURRENT ROW) AS y FROM R
