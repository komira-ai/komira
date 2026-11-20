-- order: rows
-- int64 min and max through mod()
SELECT k, mod(i, 3) AS z FROM T
