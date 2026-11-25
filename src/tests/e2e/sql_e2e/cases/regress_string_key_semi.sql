-- EXISTS on a string key: probe rows with a match, each once. Catches a
-- repeated probe key collapsed and a probe row with no match kept.
SELECT p.name AS name, p.amount AS amount FROM skey_probe AS p WHERE EXISTS (SELECT 1 FROM skey_build AS b WHERE b.rname = p.name) ORDER BY amount ASC NULLS LAST
