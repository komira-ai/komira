-- order: rows
-- A control of a bind-error shape, with the faulty part repaired: the unknown aggregate column zz replaced by the real column n
SELECT k, sum(n) OVER (PARTITION BY g ORDER BY k) AS c FROM T
