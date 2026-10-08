-- order: total
-- not null: id
-- Twin of the HAND case: TOPN 2 by a DESC, id DESC, default placement
-- NULLS LAST (§4.1), stated.
SELECT id, a, b, f
FROM sort_rows
ORDER BY a DESC NULLS LAST, id DESC NULLS LAST
LIMIT 2
