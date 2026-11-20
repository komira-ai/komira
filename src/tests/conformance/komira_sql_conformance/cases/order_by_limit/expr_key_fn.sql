-- order: query
-- ordering by a function of a column with a tie-break
SELECT k FROM T ORDER BY abs(a - 3), k
