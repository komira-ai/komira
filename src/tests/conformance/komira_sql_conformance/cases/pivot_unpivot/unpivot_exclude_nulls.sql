-- order: rows
-- EXCLUDE NULLS, the default, written; an unlisted column is kept
SELECT * FROM W UNPIVOT EXCLUDE NULLS (score FOR quarter IN (q1, q2))
