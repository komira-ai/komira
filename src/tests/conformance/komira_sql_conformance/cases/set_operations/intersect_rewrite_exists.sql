-- order: rows
SELECT DISTINCT k FROM ta a WHERE EXISTS (SELECT 1 FROM tb b WHERE b.k = a.k)
