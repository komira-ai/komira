- **Inputs that ended the process are refused.** Three inputs that used to end the Python process
  inside the engine now raise, and the session answers the next query: a statement nested more than
  100 levels deep raises `ParseError`; `lpad`, `rpad` or `repeat` asked for more than 64 MiB in one
  row raises `KomiraError` naming the per-row ceiling; a missing libz raises
  `KomiraError` `compression: cannot load <soname>: <loader error>` at the call. An abort, a fault,
  stack exhaustion or running out of memory past `memory_limit` inside the engine still ends the
  process.
