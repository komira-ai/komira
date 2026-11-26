- **Memory limit.** `Session(*, threads=None, memory_limit=None)` sets the engine's worker count and
  the bytes the operators of one query may hold in total, each a positive `int` or `None` for the
  engine's own value (`ValueError` for a value below 1 or above 2**63 - 1, `TypeError` for a
  non-`int`, before the library is called; they need libkomira ABI 1.4). A query that needs more
  memory than `memory_limit` raises the new `komira.MemoryLimitError` from `Session.sql`, with
  `status` -3, `code` `"MEMORY_BUDGET_EXCEEDED"` and `step` `"execute"`; the session answers the
  next query. The engine's message names the operator that was denied memory and the budget. Code
  that catches `KomiraError` still catches it.
