# tail and concat

`df.tail(n=5)` takes the last `n` rows of a sorted frame, in its order (see
[row order](row_order.md)).

`komira.concat([df1, df2, ...])` stacks frames of one session with the same
columns (a later frame's columns may come in another order) and the same types;
the answer has no row order.

Back to [the DataFrame overview](overview.md).
