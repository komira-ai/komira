-- order: rows
SELECT k, sqrt(f) FROM E WHERE f IS NULL OR f >= 0 OR isnan(f)
