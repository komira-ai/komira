-- order: rows
SELECT k, sum(v) OVER (PARTITION BY g ORDER BY k) AS sv FROM T
