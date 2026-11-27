-- order: rows
-- one listed column
SELECT * FROM W UNPIVOT (score FOR quarter IN (q3))
