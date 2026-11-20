-- order: rows
-- two derived tables joined to each other
SELECT a.k AS k FROM (SELECT k FROM T) a JOIN (SELECT k FROM T) b ON a.k = b.k
