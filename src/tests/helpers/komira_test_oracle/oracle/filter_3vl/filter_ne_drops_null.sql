-- order: none
-- not null: id
-- Twin of the HAND case: x <> 2 is NULL for a NULL x, so the filter drops
-- that row (§1.2).
SELECT id, x
FROM ints_nullable
WHERE x <> CAST(2 AS BIGINT)
ORDER BY id ASC NULLS LAST
