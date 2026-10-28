"""`komira_op_agg_stage` -- the stage hash aggregation.

`HashAggTable[KB, *Aggs]` (`hash_agg`), the HASH_AGG breaker state: a GROUP BY
key block (`key_block`: `KeyTupleScalar`, `AggKeyBlock[*Keys]`) and a pack of
aggregate columns (`agg_column`: `AggSlot[A]` over a `komira_agg.Aggregator`;
`agg_fn_slot`: `AggFnSlot[F, col]` over a user-defined `AggFn`).

Public API: import directly from sub-modules. No facade.
"""
