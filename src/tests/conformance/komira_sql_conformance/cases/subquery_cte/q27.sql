-- order: rows
-- one cte referenced twice (self-join)
WITH c AS (SELECT k FROM T) SELECT a.k AS k FROM c a JOIN c b ON a.k = b.k
