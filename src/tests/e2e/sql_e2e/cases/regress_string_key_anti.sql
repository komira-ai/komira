-- NOT EXISTS on a string key: bob and the NULL name. Catches the anti join
-- keeping a matched row, or dropping the NULL name (it matches nothing).
SELECT p.name AS name, p.amount AS amount FROM skey_probe AS p WHERE NOT EXISTS (SELECT 1 FROM skey_build AS b WHERE b.rname = p.name) ORDER BY amount ASC NULLS LAST
