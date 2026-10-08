-- order: none
-- not null: id
-- Twin of the HAND case: Kleene AND and OR over every pair (§1.1).
SELECT id, a, b, a AND b AS a_and_b, a OR b AS a_or_b
FROM bool_pairs
ORDER BY id ASC NULLS LAST
