-- order: rows
-- `exists (subquery)` with no correlation at all
SELECT k FROM T WHERE EXISTS (SELECT 1 FROM U b WHERE b.j = 1)
