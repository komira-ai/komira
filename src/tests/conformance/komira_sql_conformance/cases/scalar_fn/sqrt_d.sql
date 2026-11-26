-- order: rows
SELECT k, sqrt(d) FROM T WHERE d IS NULL OR d >= 0
