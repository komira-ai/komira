-- order: rows
-- Repaired form of a query that is wrong as first written: the two projected columns replaced by one scalar
SELECT k AS z FROM T WHERE v > (SELECT max(w) FROM U)
