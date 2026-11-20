-- order: rows
-- Repaired form of a query that is wrong as first written: the end-date argument supplied
SELECT date_diff('day', DATE '2021-01-01', DATE '2021-01-31') AS z FROM T
