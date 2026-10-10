# komira_net

Host resolution for the socket layer: turn a host string and a port into the
IPv4 connect targets that `komira_async`'s sockets take. Net here means DNS
only; the TCP layer is in `komira_async`.

- `parse_ip_literal(host)` never calls the resolver. `""`, `localhost` and
  `127.0.0.1` are loopback; a dotted-quad IPv4 literal is parsed. It returns
  `None` for any host with a character other than a digit or a dot (a DNS
  name), and raises on a malformed literal (wrong number of octets, an empty
  octet before a dot, an octet over 255). One trailing dot after four
  octets is accepted: `192.0.2.10.` parses as `192.0.2.10`.
- `resolve_host(host, port)` returns a literal as one target without a
  lookup; otherwise it calls `getaddrinfo` on the calling thread (a blocking
  call: never call it on a reactor thread) and returns one `SockAddr` per A
  record. It raises on an unknown name, a lookup failure or no A record.
- `resolve_host_be(host, port)` is the first target's address.
- `IpAddr` holds the family (`AF_INET`, 2) and `v4_be`, the address in
  network byte order: the first octet is the lowest byte of the `UInt32`.
  `SockAddr` pairs it with a port in host byte order.

It resolves IPv4 only: no IPv6, no SRV records, no caching.

## Examples

Literals parse without any lookup; a DNS name is `None` from the literal
path:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_raises, assert_true -->
```mojo
from komira_net.dns import IpAddr, parse_ip_literal

var ip = parse_ip_literal("192.0.2.10")
assert_true(ip.__bool__())
assert_true(ip.value().is_ipv4())
assert_equal(ip.value().family, 2)
assert_equal(ip.value().v4_be, 0x0A0200C0)  # bytes 192, 0, 2, 10 in memory order

assert_equal(parse_ip_literal("localhost").value().v4_be, 0x0100007F)
assert_equal(parse_ip_literal("").value().v4_be, 0x0100007F)
assert_false(parse_ip_literal("db.example.com").__bool__())  # needs DNS

with assert_raises():
    _ = parse_ip_literal("192.0.2")  # three octets
with assert_raises():
    _ = parse_ip_literal("192.0.2.256")  # octet out of range
with assert_raises():
    _ = parse_ip_literal("192..2.10")  # empty octet
assert_equal(parse_ip_literal("192.0.2.10.").value().v4_be, 0x0A0200C0)  # trailing dot
```

`resolve_host` on a literal returns it as the only target and does not call
`getaddrinfo`:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_net.dns import resolve_host, resolve_host_be

var targets = resolve_host("198.51.100.7", 8080)
assert_equal(len(targets), 1)
assert_equal(targets[0].port, 8080)
assert_equal(targets[0].ip.v4_be, 0x076433C6)
assert_equal(resolve_host_be("127.0.0.1", 5432), 0x0100007F)
```
