-- order: rows
SELECT k, a FROM T WHERE CASE WHEN a > 3 THEN true END
