-- order: rows
-- int64 min through mod() in where
SELECT k FROM T WHERE mod(i, 3) = -2
