-- order: none
-- not null: id
-- Twin of the HAND case: a comparison with a NULL value is NULL (§1.2).
SELECT
    id,
    x = CAST(2 AS BIGINT) AS eq_2,
    x <> CAST(2 AS BIGINT) AS ne_2,
    x > CAST(1 AS BIGINT) AS gt_1
FROM ints_nullable
ORDER BY id ASC NULLS LAST
