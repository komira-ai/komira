-- Ranks and a running count over an order key whose NULLs are placed first,
-- where the NULL rows are peers of each other.
SELECT id, k, v, rank() OVER (PARTITION BY k ORDER BY v DESC NULLS FIRST) AS rk, dense_rank() OVER (PARTITION BY k ORDER BY v ASC NULLS FIRST) AS drk, count(*) OVER (PARTITION BY k ORDER BY v ASC NULLS FIRST) AS running FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
