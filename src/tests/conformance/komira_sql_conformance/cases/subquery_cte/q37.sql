-- order: rows
-- `in (subquery)` whose body is a cte
WITH c AS (SELECT j FROM U) SELECT k FROM T WHERE k IN (SELECT j FROM c)
