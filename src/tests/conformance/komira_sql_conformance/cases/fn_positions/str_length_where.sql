-- order: rows
-- non-ascii through length() in where
SELECT k FROM T WHERE length(s) > 2
