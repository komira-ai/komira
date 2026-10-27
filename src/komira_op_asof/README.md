# komira_op_asof

The ASOF join: for each left row, the right row with the same equi key whose
ASOF value is the nearest at or before (BACKWARD), at or after (FORWARD), or
either side (NEAREST) of the left row's. The package root re-exports nothing;
import from the modules.

It answers as DuckDB's `ASOF JOIN` does (`l.t >= r.t` is BACKWARD, `l.t <=
r.t` FORWARD):

- a NULL equi key matches nothing, on either side, and neither does a NULL
  ASOF value;
- float keys and float ASOF values compare in the sort's order
  (`komira_op_sort.sort.sort_key_lt`): NaN equals NaN and sorts above +inf,
  and -0.0 equals +0.0;
- an equal ASOF value matches. Among right rows with equal key and ASOF
  value, BACKWARD takes the last in input order and FORWARD the first (DuckDB
  leaves that choice unspecified).

NEAREST and the tolerance are the engine's own (DuckDB has neither). NEAREST
breaks a distance tie toward the backward row; the tolerance is inclusive; a
NaN is never within a finite distance of a number.

- `komira_op_asof.asof_walker`: `asof_merge_into[strategy, dtype]`, the
  two-cursor merge over sorted sides, and `asof_merge_dispatch`, its run-time
  (strategy, dtype) switch (INT32, INT64, FLOAT64 ASOF values);
  `compare_equi_keys` (INT32, INT64, FLOAT64, STRING and DICTIONARY keys) and
  `compare_keys`. The sort places a NULL numeric key by the value in its slot;
  the walker steps over such rows instead of trusting their position.
- `komira_op_asof.asof_kernel`: the search of one left value in a right
  group, `_find_best_asof[strategy, dtype]`, with its hinted bounds and
  `AsofValue`.
- `komira_op_asof.asof_equi_key`: `EquiKeyCmp`, a comparison's sort order
  (`order`, two NULLs adjacent) apart from its join match (`matched`, never
  for a NULL).
