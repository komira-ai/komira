-- order: rows
-- last_day of a DATE column, with NULL, infinity and -infinity
SELECT k, last_day(dt) FROM T
