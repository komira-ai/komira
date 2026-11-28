-- order: rows
-- last_day of two TIMESTAMP columns
SELECT k, last_day(t), last_day(v) FROM T
