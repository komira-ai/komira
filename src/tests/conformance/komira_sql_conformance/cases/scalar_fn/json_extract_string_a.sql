-- order: rows
SELECT k, json_extract_string(j, '$.a') FROM E
