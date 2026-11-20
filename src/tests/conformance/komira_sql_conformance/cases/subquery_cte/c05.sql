-- order: rows
-- the flat spelling of q26/q30 the join with no cte on either side
SELECT a.k AS k, b.w AS w FROM T a JOIN U b ON a.k = b.j
