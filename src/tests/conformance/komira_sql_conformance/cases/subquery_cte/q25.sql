-- order: rows
-- two ctes, the second one selected from
WITH c AS (SELECT k FROM T), d AS (SELECT j FROM U) SELECT j FROM d
