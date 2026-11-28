-- order: rows
-- last_day applied to the result of make_date on the first of the month
SELECT k, last_day(make_date(yr, mo, 1)) FROM T
