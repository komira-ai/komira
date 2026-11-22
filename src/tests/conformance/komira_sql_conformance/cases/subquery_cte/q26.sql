-- order: rows
-- two ctes, both used, joined to each other
WITH c AS (SELECT k FROM T), d AS (SELECT j, w FROM U) SELECT a.k AS k, b.w AS w FROM c a JOIN d b ON a.k = b.j
