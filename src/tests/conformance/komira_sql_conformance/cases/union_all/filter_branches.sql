-- order: rows
-- a WHERE in each branch
SELECT id, bi FROM A WHERE id > 1 UNION ALL SELECT id, bi FROM B WHERE id < 12
