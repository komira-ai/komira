-- order: rows
-- non-ascii through length() -- chars, not bytes
SELECT k, length(s) AS z FROM T
