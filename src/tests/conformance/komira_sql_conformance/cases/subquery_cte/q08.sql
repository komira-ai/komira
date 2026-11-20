-- order: rows
-- a scalar subquery compared against a literal (no outer column)
SELECT k FROM T WHERE (SELECT count(*) FROM U) = 4
