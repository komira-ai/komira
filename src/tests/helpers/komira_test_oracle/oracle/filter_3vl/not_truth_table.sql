-- order: none
-- not null: id
-- Twin of the HAND case: NOT over TRUE, FALSE, NULL (§1.1).
SELECT id, a, NOT a AS not_a
FROM bool_pairs
ORDER BY id ASC NULLS LAST
