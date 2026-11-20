-- order: rows
-- +-inf and nan through isinf()
SELECT k, isinf(f) AS z FROM T
