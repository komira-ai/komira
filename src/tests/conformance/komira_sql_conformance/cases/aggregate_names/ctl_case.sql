-- order: rows
SELECT k, CASE WHEN i > 15 THEN 'big' WHEN i IS NULL THEN 'nil' ELSE 'small' END AS r FROM N
