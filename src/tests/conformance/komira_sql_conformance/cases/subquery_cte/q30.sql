-- order: rows
-- a cte joined to a base table
WITH c AS (SELECT j, w FROM U) SELECT a.k AS k, b.w AS w FROM T a JOIN c b ON a.k = b.j
