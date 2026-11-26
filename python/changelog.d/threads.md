- **Threads.** A `Session` may be used from several threads: its calls run one at a time, a call waiting
  for the one running on the same session, and `close()` waits for a running call. Two sessions run at
  once. A call from a signal handler, a finalizer or a `progress` callback made inside a running call of the same thread raises
  `KomiraError`. Of two threads reading one `Result`, one reads it and the other gets `KomiraError`. Using
  one session from two threads at once was not supported.
