-- order: rows
-- int64 min through sign() in where
SELECT k FROM T WHERE sign(i) < 0
