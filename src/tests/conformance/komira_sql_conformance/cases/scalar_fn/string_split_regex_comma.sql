-- order: rows
SELECT k, string_split_regex(s, ',') FROM T
