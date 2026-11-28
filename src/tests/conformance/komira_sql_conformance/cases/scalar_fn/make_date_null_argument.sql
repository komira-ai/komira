-- order: rows
-- make_date with a NULL literal in each argument position
SELECT k, make_date(NULL, mo, dy), make_date(yr, NULL, dy), make_date(yr, mo, NULL) FROM T
