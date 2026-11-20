-- order: rows
-- whole-partition frame with no PARTITION BY over a key with ties
SELECT k, max(v) OVER (ORDER BY o ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS y FROM T
