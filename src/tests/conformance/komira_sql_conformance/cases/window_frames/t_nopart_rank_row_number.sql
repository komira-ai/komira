-- order: rows
-- ranking over a key with ties and no PARTITION BY
SELECT y FROM (SELECT k, row_number() OVER (ORDER BY o) AS y FROM T)
