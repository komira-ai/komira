-- order: rows
SELECT k, jaro_winkler_similarity(s, u) FROM T
