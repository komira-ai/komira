-- order: rows
SELECT k, a FROM T WHERE CASE WHEN COALESCE(a, -1) < 0 THEN false ELSE GREATEST(a, b) > 2 END
