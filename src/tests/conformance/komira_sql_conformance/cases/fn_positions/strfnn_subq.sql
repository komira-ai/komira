-- order: rows
-- strpos(s, 'b') inside a scalar subquery
SELECT k, (SELECT max(strpos(s, 'b')) FROM T) AS z FROM T
