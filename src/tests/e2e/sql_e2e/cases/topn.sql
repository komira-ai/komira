-- ORDER BY with LIMIT: ties at the cut broken by id.
SELECT id, i32 FROM nulls ORDER BY i32 DESC NULLS LAST, id ASC NULLS LAST LIMIT 10
