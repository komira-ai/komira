-- order: rows
-- a branch with no row
SELECT id, i FROM A UNION ALL SELECT id, i FROM B WHERE false
