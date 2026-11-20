-- order: rows
-- Repaired form of a query that is wrong as first written: the group index -1 replaced by 1
SELECT regexp_extract(s, '(a)(b)', 1) AS z FROM T
