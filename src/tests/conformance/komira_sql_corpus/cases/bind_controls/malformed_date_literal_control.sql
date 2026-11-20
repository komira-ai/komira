-- order: rows
-- Repaired form of a query that is wrong as first written: the unparseable literal replaced by a real date
SELECT date_diff('day', DATE '2021-02-28', DATE '2021-03-01') AS z FROM T
