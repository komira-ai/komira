"""`net` -- host resolution above the socket layer.

The DNS resolver: `parse_ip_literal` (IP-literal fast path), `resolve_host`
and `resolve_host_be` (IPv4 `getaddrinfo` on the calling thread, before any
reactor `connect`), and the `IpAddr` / `SockAddr` value types. Consumers
import directly via `from net.dns import <name>`.

Net here means DNS only. The TCP layer stays in `async_rt`, whose
`reactor.socket_setup` this package imports.
"""
