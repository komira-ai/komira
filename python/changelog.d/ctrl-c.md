- **Ctrl-C.** Ctrl-C during `Session.sql` cancels the query: the engine stops at its next check,
  `sql` raises `KeyboardInterrupt`, and the session runs the next query. Before, a query could not be
  interrupted: the `KeyboardInterrupt` came only once the engine had finished it. The query now runs on
  a helper thread while the calling thread waits for it. Nothing a cancelled query computed is kept.
  Cancel and progress need libkomira ABI 1.6, which the wheel carries; with an older library a query
  still cannot be interrupted, and `progress` raises `KomiraError`.
