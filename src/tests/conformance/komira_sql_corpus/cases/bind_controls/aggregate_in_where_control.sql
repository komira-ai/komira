-- order: rows
-- Repaired form of a query that is wrong as first written: the aggregate moved out of WHERE into the SELECT list
SELECT median(v) AS z FROM T
