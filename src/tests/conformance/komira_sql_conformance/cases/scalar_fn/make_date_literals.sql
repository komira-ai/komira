-- order: rows
-- make_date of constant arguments, a leap day and a non-leap February end
SELECT k, make_date(2024, 2, 29), make_date(2028, 2, 29), make_date(2000, 2, 29), make_date(2100, 2, 28), make_date(2015, 12, 31) FROM T
