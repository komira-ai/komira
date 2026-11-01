"""Helpers for tests of mail servers that run over real loopback sockets:
`Peer`, a non-blocking client (plaintext or TLS) that a test drives next to a
polled server, `read_fixture` for the TLS test certificates, `scratch_dir` and
`yield_cpu`.

A test that owns both ends of a connection in one thread cannot block: it
calls the server's step, then `Peer.poll`, until what it waits for has arrived.
`yield_cpu` between attempts lets the kernel move the bytes; nothing here
measures time or gives up, so a hung server shows as a hung test.

| name | does |
|---|---|
| `Peer` | `connect`, `send`, `send_bytes`, `poll`, `has`, `take_through`, `start_tls`, `tls_step`, `close`, `reset` |
| `read_fixture` | a PEM file of komira_http_core's test fixtures |
| `scratch_dir` | the run's private scratch directory |
| `yield_cpu` | `sched_yield` |
"""

from .peer import Peer, read_fixture, scratch_dir, yield_cpu
