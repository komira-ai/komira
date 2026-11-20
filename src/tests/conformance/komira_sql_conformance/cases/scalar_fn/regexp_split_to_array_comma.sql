-- order: rows
SELECT k, regexp_split_to_array(s, ',') FROM T
