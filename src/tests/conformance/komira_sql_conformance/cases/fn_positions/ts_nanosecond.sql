-- order: rows
-- timestamp through nanosecond()
SELECT k, nanosecond(t) AS z FROM T
