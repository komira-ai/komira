-- order: rows
-- make_date with a month and a day computed from k, so some rows are not dates
SELECT k, make_date(2015, k % 12 + 1, k + 1), make_date(2028, 2, k + 17), make_date(2100, 2, k + 16), make_date(2000, 2, k + 17) FROM T
