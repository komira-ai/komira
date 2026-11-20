-- order: rows
SELECT COUNT(*) AS c FROM T WHERE v > 2 AND NOT (s LIKE '%z')
