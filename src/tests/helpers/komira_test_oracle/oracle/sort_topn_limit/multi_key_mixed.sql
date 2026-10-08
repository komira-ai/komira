-- order: keys=a,b
-- not null: id
-- Twin of the HAND case: a ASC NULLS FIRST, then b DESC NULLS LAST (§4.2).
-- id only fixes the order of this file's tie groups (§4.7).
SELECT id, a, b, f
FROM sort_rows
ORDER BY a ASC NULLS FIRST, b DESC NULLS LAST, id ASC NULLS LAST
