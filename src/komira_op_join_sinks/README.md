# komira_op_join_sinks

The per-worker operators a join pipeline constructs over the join probe
(`komira_op_join_probe`). The package root re-exports nothing; import from the
modules.

- `komira_op_join_sinks.join_probe_op_adapter`: `JoinProbeOpAdapter`, the
  single-key join probe a driver allocates per worker
  (`Slab[JoinProbeOpAdapter]`). It wraps one `JoinProbeOp`, takes its
  constructor arguments in the same order with the same defaults, and returns
  its results and metrics unchanged: the resumable INNER arm's
  HAVE_MORE_OUTPUT chunks, the deferred INNER output, the perfect-hash and
  radix INNER, LEFT, SEMI and ANTI.
- `komira_op_join_sinks.multi_probe_op_adapter`: the probe cascades, which run
  a chain of joins against finished builds over one morsel, each probe's
  output the next probe's input. `MultiProbeOpAdapter` chains single-key
  `JoinProbeOp`s and `MultiKeyProbeCascadeAdapter` chains composite-key
  `MultiKeyJoinProbeOp`s. With one probe, either adapter is that probe. With
  more, every probe must finish its morsel in one call: a probe that returns
  HAVE_MORE_OUTPUT is an error, not a cut-short answer. A probe whose output
  is empty ends the chain for that morsel. An empty cascade is refused.
- `komira_op_join_sinks.finalized_hash_index`: `FinalizedHashIndex`, a finished
  single-INT64-key table (`komira_op_join_build`'s `HashJoinBuilder`), the
  build batch it indexes, and a matched flag per build row that any worker may
  set (`mark_matched`, a relaxed atomic store). `collect_marked_indices` lists
  the rows whose flag is set or clear, ascending, each once.
- `komira_op_join_sinks.mark_semi_anti`: `MarkSemiAntiProbeOp`, the marking
  pass of a SEMI or ANTI join that builds its LEFT side and streams its RIGHT
  side. Each RIGHT morsel marks every LEFT row whose key it holds; the morsel
  is emptied (NEED_MORE_INPUT), and after the workers finish the caller reads
  the SEMI rows (flag set) or ANTI rows (flag clear) from the index, in LEFT
  row order. A NULL key on either side matches nothing, and a RIGHT row the
  morsel's selection mask excludes marks nothing. Keys are INT64; a key column
  of another type is refused, as the single-key probe refuses it.

## Tests

The tests are welded into the library target, so building
`//src/komira_op_join_sinks:komira_op_join_sinks` runs them:

- `test_join_probe_op_adapter`: every join type with a NULL probe key against
  the rows written in the test and against a bare `JoinProbeOp`; SEMI count
  only; the resumable INNER arm's two chunks; the metrics.
- `test_multi_probe_op_adapter`: one probe, a two-probe cascade row by row, an
  empty first probe, the refusal of a probe that returns HAVE_MORE_OUTPUT
  inside a cascade, the empty cascade, and a composite cascade with NULL keys
  and FLOAT64 keys (NaN equals NaN, -0.0 equals +0.0).
- `test_mark_semi_anti`: the SEMI and ANTI answers over every chain-entry
  layout of the table with the bloom on and off, two workers sharing one
  index, the selection mask, a nested-loop cross-check over 2,000 by 9,000
  rows, empty sides, the index's checks, and the refusal of a FLOAT64 key.
