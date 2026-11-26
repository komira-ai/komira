-- order: rows
-- make_date over the year, month and day columns: leap and non-leap Februaries, a NULL in each part
SELECT k, make_date(yr, mo, dy) FROM T
