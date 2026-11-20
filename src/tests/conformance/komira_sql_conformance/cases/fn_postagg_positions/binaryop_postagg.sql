-- order: rows
-- multiply(sum(k), 3) around an aggregate in the select list
SELECT multiply(sum(k), 3) AS z FROM T
