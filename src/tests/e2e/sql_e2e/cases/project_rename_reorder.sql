-- Columns selected out of order and renamed.
SELECT s AS word, id AS row_id, k AS grp FROM nulls WHERE id < 50 ORDER BY row_id ASC NULLS LAST
