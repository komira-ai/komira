-- order: none
-- not null: id
-- Twin of the HAND case: a filter keeps a row only when NOT (a AND b) is
-- TRUE (§1.1, §1.2).
SELECT id, a, b
FROM bool_pairs
WHERE NOT (a AND b)
ORDER BY id ASC NULLS LAST
