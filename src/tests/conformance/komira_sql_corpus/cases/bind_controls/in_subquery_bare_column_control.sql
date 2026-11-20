-- order: rows
-- Repaired form of a query that is wrong as first written: the computed projection j + 1 replaced by the bare column j
SELECT k AS z FROM T WHERE k IN (SELECT j FROM U)
