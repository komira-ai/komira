-- order: rows
SELECT k, has_any_column_privilege('T', 'SELECT') FROM T
