-- order: rows
-- a scalar subquery whose body reads a cte
WITH c AS (SELECT j FROM U) SELECT k, (SELECT max(j) FROM c) AS m FROM T
