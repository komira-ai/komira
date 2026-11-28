-- order: rows
-- a DATE column compared in a WHERE with make_date of constant arguments
SELECT k FROM T WHERE dt >= make_date(2015, 1, 1)
