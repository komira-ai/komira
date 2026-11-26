- **Grouped float aggregates.** `Session.sql` answers `GROUP BY` with `sum`, `avg`, `min`, `max` and
  `count` of a `FLOAT` or `DOUBLE` column or expression, where it raised `UnsupportedOperation`
  before. NULL, NaN, infinities and `-0.0` give DuckDB's answers, and a group's `sum` and `avg` are
  the same bits on every thread count. Such a query does not spill: over the memory budget it
  raises `MemoryLimitError`.
