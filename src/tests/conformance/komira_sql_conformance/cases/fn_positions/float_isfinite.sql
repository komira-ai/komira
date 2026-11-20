-- order: rows
-- +-inf and nan through isfinite()
SELECT k, isfinite(f) AS z FROM T
