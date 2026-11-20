-- order: rows
-- `exists (subquery)` whose body is a cte
WITH c AS (SELECT j FROM U) SELECT k FROM T a WHERE EXISTS (SELECT 1 FROM c b WHERE b.j = a.k)
