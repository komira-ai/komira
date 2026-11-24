-- LEFT JOIN on a string key. Catches an unmatched probe row (bob, the NULL
-- name) dropped or not NULL-padded on the build columns.
SELECT p.name AS name, p.amount AS amount, b.region_id AS region_id, b.priority AS priority FROM skey_probe AS p LEFT JOIN skey_build AS b ON p.name = b.rname ORDER BY amount ASC NULLS LAST
