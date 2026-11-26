# tail and concat

> **Newer than 0.1.1623.** komira 0.1.1623 and older releases do not have what this page describes. [The changelog](../../CHANGELOG.md) lists what each release added.

`df.tail(n=5)` takes the last `n` rows of a sorted frame, in its order (see
[row order](row_order.md)).

`komira.concat([df1, df2, ...])` stacks frames of one session with the same
columns (a later frame's columns may come in another order) and the same types;
the answer has no row order.

Back to [the DataFrame overview](overview.md).
