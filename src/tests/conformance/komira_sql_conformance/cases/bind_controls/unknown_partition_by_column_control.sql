-- order: rows
-- A control of a bind-error shape, with the faulty part repaired: the unknown partition key zz replaced by the real column g
SELECT k, count(*) OVER (PARTITION BY g ORDER BY k) AS c FROM T
