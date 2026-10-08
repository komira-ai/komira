-- order: keys=a
-- not null: id
-- Twin of the HAND case: a ASC NULLS FIRST (§4.2). id only fixes the order
-- of this file's tie groups, which the policy compares as multisets (§4.7).
SELECT id, a, b, f
FROM sort_rows
ORDER BY a ASC NULLS FIRST, id ASC NULLS LAST
