# =============================================================================
# komira_async.net — higher-level net helpers above the socket layer
# =============================================================================
# Sibling of `reactor/` (the FFI socket/bind/listen/epoll layer). `net/` holds
# helpers that sit ABOVE the socket layer and BELOW the network clients
# (komira_pg, komira_http): address value types (IpAddr, SockAddr) and the
# host-resolution layer (dns.mojo).
#
# This
# module is NOT reactor-internal — it never touches Reactor / epoll / the
# completion queue. Resolution runs on the calling thread, above the socket
# layer, before any reactor `connect`. The reactor is never handed a hostname.
# =============================================================================
