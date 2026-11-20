-- order: rows
-- Repaired form of a query that is wrong as first written: the unknown aggregate column zz replaced by the real column n
SELECT k, sum(n) OVER (PARTITION BY g ORDER BY k) AS c FROM T
