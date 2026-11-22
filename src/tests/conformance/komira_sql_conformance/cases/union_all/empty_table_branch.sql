-- order: rows
-- a branch over an empty table, first and last
SELECT id, i FROM EMPTY UNION ALL SELECT id, i FROM A UNION ALL SELECT id, i FROM EMPTY
