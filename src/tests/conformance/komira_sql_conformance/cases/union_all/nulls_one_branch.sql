-- order: rows
-- NULLs in one branch only
SELECT id, ti FROM A UNION ALL SELECT id, 1 FROM B
