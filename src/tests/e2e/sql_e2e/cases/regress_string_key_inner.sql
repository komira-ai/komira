-- INNER JOIN on a string key, alice twice on the probe side, '' on both
-- sides, a NULL name. Catches a string-key join refused or matching wrong
-- rows, a repeated probe key emitted once, and NULL matching NULL.
SELECT p.name AS name, p.amount AS amount, b.region_id AS region_id, b.priority AS priority FROM skey_probe AS p JOIN skey_build AS b ON p.name = b.rname ORDER BY amount ASC NULLS LAST
