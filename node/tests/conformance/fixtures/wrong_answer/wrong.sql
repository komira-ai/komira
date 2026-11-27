-- order: query
-- The DOUBLE of each row in k order. Its committed answer is wrong in one
-- cell, the d of k = 2: the runner must report this case alone.
SELECT k, d FROM W ORDER BY k
