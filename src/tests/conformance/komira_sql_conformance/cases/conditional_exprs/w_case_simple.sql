-- order: rows
SELECT k, a FROM T WHERE CASE a WHEN 1 THEN true WHEN 0 THEN true ELSE false END
