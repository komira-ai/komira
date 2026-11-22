-- order: query
-- ORDER BY and LIMIT after the last branch apply to the whole union
SELECT id, bi FROM A UNION ALL SELECT id, bi FROM B ORDER BY id DESC LIMIT 4
