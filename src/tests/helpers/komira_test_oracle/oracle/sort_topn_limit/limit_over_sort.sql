-- order: none
-- not null: id
-- Twin of the HAND case: LIMIT 2 over a ASC NULLS LAST (§4.2); a = 1 and
-- a = 2 are single rows, so the two rows are fixed.
SELECT id, a, b, f
FROM sort_rows
ORDER BY a ASC NULLS LAST
LIMIT 2
