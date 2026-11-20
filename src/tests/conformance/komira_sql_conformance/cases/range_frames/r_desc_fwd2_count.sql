-- order: rows
-- descending key: PRECEDING measures toward larger key values (a forward value window of width 2)
SELECT k, count(v) OVER (PARTITION BY g ORDER BY o DESC RANGE BETWEEN CURRENT ROW AND 2 FOLLOWING) AS y FROM R
