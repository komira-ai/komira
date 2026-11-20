-- order: rows
-- descending key: PRECEDING measures toward larger key values (a value window behind the current row that excludes it; empty where no key falls in it)
SELECT k, min(v) OVER (PARTITION BY g ORDER BY o DESC RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING) AS y FROM R
