-- order: rows
SELECT k FROM T WHERE NOT (tag = 'y3' AND tag LIKE 'y%')
