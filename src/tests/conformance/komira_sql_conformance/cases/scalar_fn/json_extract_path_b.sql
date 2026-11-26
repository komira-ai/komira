-- order: rows
SELECT k, json_extract_path(j, '$.b') FROM E
