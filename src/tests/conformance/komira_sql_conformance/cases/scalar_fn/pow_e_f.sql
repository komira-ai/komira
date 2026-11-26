-- order: rows
SELECT k, pow(f, 0.5) FROM E WHERE f IS NULL OR f >= 0 OR isnan(f)
