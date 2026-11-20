-- order: rows
SELECT k, a FROM T WHERE CASE WHEN a IS NULL THEN false ELSE a > 2 END
