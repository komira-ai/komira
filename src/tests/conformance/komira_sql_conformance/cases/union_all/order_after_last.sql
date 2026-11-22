-- order: query
-- ORDER BY after the last branch sorts the whole union
SELECT id, s FROM A UNION ALL SELECT id, s FROM B ORDER BY id DESC
