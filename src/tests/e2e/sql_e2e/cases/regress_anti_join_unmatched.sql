-- NOT EXISTS on INT64 keys: the probe rows with no build match (4..7), probe
-- columns only. Catches a wrong anti row set.
SELECT p.key AS key, p.left_val AS left_val FROM pad_probe AS p WHERE NOT EXISTS (SELECT 1 FROM pad_build AS b WHERE b.key = p.key) ORDER BY key ASC NULLS LAST
