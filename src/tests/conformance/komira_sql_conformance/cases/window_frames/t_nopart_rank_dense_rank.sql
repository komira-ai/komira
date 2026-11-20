-- order: rows
-- ranking over a key with ties and no PARTITION BY
SELECT k, dense_rank() OVER (ORDER BY o) AS y FROM T
