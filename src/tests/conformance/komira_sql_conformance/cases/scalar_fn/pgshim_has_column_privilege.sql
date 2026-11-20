-- order: rows
SELECT k, has_column_privilege('T', 's', 'SELECT') FROM T
