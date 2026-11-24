-- IN and NOT IN as values: NULL when the operand is NULL.
SELECT id, k IN (1, 3) AS is_in, k NOT IN (1, 3) AS not_in FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
