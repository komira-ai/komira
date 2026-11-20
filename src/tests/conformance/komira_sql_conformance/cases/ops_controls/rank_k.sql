-- order: rows
SELECT k, rank() OVER (PARTITION BY g ORDER BY k) AS r FROM T
