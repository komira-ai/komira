-- order: rows
SELECT min(CASE WHEN a > 3 THEN a ELSE b END) AS lo, max(CASE WHEN a > 3 THEN a ELSE b END) AS hi FROM T
