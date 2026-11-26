-- order: rows
SELECT k, json_extract_string(j, '$.b') FROM E
