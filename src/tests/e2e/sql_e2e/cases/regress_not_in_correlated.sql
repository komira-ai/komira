-- NOT IN over a correlated subquery: (40, 9), whose subquery is empty, is
-- kept. Catches the correlation ignored and an empty set treated as a
-- NULL.
SELECT o.k AS k, o.c AS c FROM in_outer AS o WHERE o.k NOT IN (SELECT t.i FROM in_inner AS t WHERE t.j = o.c) ORDER BY k ASC NULLS LAST, c ASC NULLS LAST
