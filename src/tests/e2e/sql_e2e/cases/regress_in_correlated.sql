-- IN over a correlated subquery: k must be among the i of the inner rows
-- whose j equals the outer c. Catches the correlation ignored ((10, 2)
-- kept), the correlation and IN keys swapped, and a wrong row set.
SELECT o.k AS k, o.c AS c FROM in_outer AS o WHERE o.k IN (SELECT t.i FROM in_inner AS t WHERE t.j = o.c) ORDER BY k ASC NULLS LAST, c ASC NULLS LAST
