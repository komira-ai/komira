-- order: rows
SELECT COUNT(*) AS c FROM T WHERE (3 * v + 5) > 14 AND NOT (note LIKE 'z%')
