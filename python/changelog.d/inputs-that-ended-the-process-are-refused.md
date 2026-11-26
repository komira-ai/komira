- **Inputs that ended the process are refused.** Three inputs that used to end the Python process
  inside the engine now raise, and the session answers the next query: a statement nested more than
  100 levels deep raises `ParseError`; `lpad`, `rpad` or `repeat` asked for more than 64 MiB in one
  row raises `KomiraError` naming the per-row ceiling; a missing libzstd, libz or liblz4 raises
  `KomiraError` `<package>: cannot load <soname>: <loader error>` at each query that reads a
  page or file of its codec, and files that use none of its codecs read as before (macOS has no
  libzstd or liblz4). An abort, a fault,
  stack exhaustion or running out of memory past `memory_limit` inside the engine still ends the
  process.
