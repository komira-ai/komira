-- order: rows
-- Repaired form of a query that is wrong as first written: the unknown partition key zz replaced by the real column g
SELECT k, count(*) OVER (PARTITION BY g ORDER BY k) AS c FROM T
