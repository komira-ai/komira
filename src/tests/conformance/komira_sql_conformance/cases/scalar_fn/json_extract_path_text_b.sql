-- order: rows
SELECT k, json_extract_path_text(j, '$.b') FROM E
