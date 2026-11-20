-- order: rows
-- strpos(s, 'b') as an aggregate argument
SELECT max(strpos(s, 'b')) AS z FROM T
