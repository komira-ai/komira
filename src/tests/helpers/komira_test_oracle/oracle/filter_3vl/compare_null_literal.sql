-- order: none
-- not null: id
-- Twin of the HAND case: a comparison with a NULL literal is NULL (§1.2).
-- The NULL literal is the plan's INT64 NULL.
SELECT
    id,
    x = CAST(NULL AS BIGINT) AS eq_null,
    x <> CAST(NULL AS BIGINT) AS ne_null,
    x < CAST(NULL AS BIGINT) AS lt_null
FROM ints_nullable
ORDER BY id ASC NULLS LAST
