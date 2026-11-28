- **Unix counts to timestamps.** `komira.to_datetime(series, unit=...)` turns a Series of integer
  Unix counts into a timestamp Series, as `pandas.to_datetime` does for an integer with a `unit`:
  `unit` is `"s"`, `"ms"`, `"us"` or `"ns"` (pandas' default), counted from 1970-01-01, naive.
  `"s"`, `"ms"` and `"us"` answer `timestamp_us` and `"ns"` answers `timestamp_ns`; a missing
  count stays missing, and a count too large for the type raises the engine's overflow error. A
  float, uint64, text or temporal Series, any other `unit`, and the arguments for parsing text or
  for zones (`format`, `dayfirst`, `yearfirst`, `exact`, `infer_datetime_format`, `utc`), a
  non-unix `origin` and `errors="coerce"` or `"ignore"` raise `UnsupportedOperation` naming them.
  `komira.to_datetime` is no longer a refused name; `to_numeric` still is.
