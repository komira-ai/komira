"""`komira_op_typed_source_api` -- the contract of the engine's typed sources.

The `TypedSource` and `SourceReader` traits, `FlatContribution` and the leaf
aggregation's RADIX-by-rows decision (`typed_source`), and the CSV, JSONL and
Avro OCF row-format conformers (`csv_typed_source`, `jsonl_typed_source`,
`avro_typed_source`). Nothing here reads the environment.

Public API: import directly from sub-modules. No facade.
"""
