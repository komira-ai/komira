-- order: rows
SELECT COUNT(*) AS c FROM T WHERE NOT (s LIKE 'z%')
