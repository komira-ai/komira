# =============================================================================
# komira_net.dns — host resolution above the socket layer
# =============================================================================
# The DNS resolver: API surface, FFI/SAFETY plan, IP-literal fast path,
# error model. IPv4 (AF_INET) only. HTTP-site wiring, caching, IPv6 and
# per-core blocking-IO offload are OUT OF SCOPE here.
#
# Why this lives ABOVE the socket layer and never touches the reactor:
# `getaddrinfo(3)` is a SYNCHRONOUS, BLOCKING call. Resolution happens on the
# CALLING thread at the host-parse site, before any reactor `connect`. The
# reactor is never handed a hostname — only the resolved `ip_be`. This is
# correct-by-construction for the per-core run-to-completion model because the
# blocking call provably never executes inside `poll_completions`.
#
# Public API (all return SAFE typed values — no UnsafePointer crosses the
# module boundary; mirrors socket_setup.mojo's FFI-shim house style):
#   - parse_ip_literal(host) raises -> Optional[IpAddr]   # IP-literal fast path
#   - resolve_host(host, port) raises -> List[SockAddr]    # literal-or-getaddrinfo
#   - resolve_host_be(host, port) raises -> UInt32         # first A record, ip_be
#
# Pointer discipline:
#   - The ONLY code that touches `struct addrinfo` is the private thunk
#     `_getaddrinfo_collect`. The raw `addrinfo*` is held in a local with a
#     CONCRETE origin (never a wildcard), and `freeaddrinfo` is called on EVERY
#     exit path — including the raises path (free-then-raise shape, since Mojo
#     has no `defer`). The returned `List[IpAddr]` is a deep copy holding no
#     glibc memory.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.memory import UnsafePointer
from std.collections import Optional

from komira_async.reactor.socket_setup import inet_loopback_be


@always_inline
def _null_ext_byte() -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """A raw NULL FFI byte pointer with the (kept) `MutExternalOrigin` carve-out
    origin — replaces the b2-removed `UnsafePointer[UInt8, o]()` null ctor for
    the getaddrinfo `**res` out-slot's initial fill.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the all-
    # zero (NULL) bit pattern. NOT the banned `unsafe_from_address=Int(0)`. The
    # `MutExternalOrigin` wildcard is the documented FFI carve-out for the
    # genuinely-glibc-owned addrinfo list this slot receives (see the res_slot
    # SAFETY block); the slot is a throwaway stack local freed before return,
    # never a struct field — so the destroy-recreate field ban does not apply.
    """
    var none: Optional[UnsafePointer[UInt8, MutUntrackedOrigin]] = None
    return UnsafePointer(to=none).bitcast[
        UnsafePointer[UInt8, MutUntrackedOrigin]
    ]()[]


# -----------------------------------------------------------------------------
# Constants — AF_INET / SOCK_STREAM / getaddrinfo hints + EAI_* codes.
# -----------------------------------------------------------------------------

comptime _AF_INET: Int32 = Int32(2)        # AF_INET == 2 on BOTH glibc + BSD/Darwin
comptime _SOCK_STREAM: Int32 = Int32(1)    # SOCK_STREAM == 1 on BOTH

# AI_ADDRCONFIG — return addresses only for families the local host has a
# configured interface for (avoids returning A records on an IPv6-only host and
# vice versa). The CONSTANT VALUE DIFFERS by platform:
#   - glibc netdb.h:           0x0020
#   - BSD/Darwin netdb.h:      0x0400
# The resolver forces ai_family=AF_INET anyway, but we pass the correct per-platform
# flag so the hints struct is honored rather than silently ignored.
comptime _AI_ADDRCONFIG: Int32 = (
    Int32(0x0400) if CompilationTarget.is_macos() else Int32(0x0020)
)

# EAI_* return codes (NOT errno). Mapped to error model (distinct
# DnsError[...] message prefixes). THE CODES DIFFER by platform — glibc uses
# NEGATIVE values, BSD/Darwin uses POSITIVE values:
#                         glibc   BSD/Darwin
#   EAI_NONAME  (NXDOMAIN)  -2          8
#   EAI_AGAIN   (transient) -3          2
#   EAI_FAIL    (perm fail) -4          4
#   EAI_SYSTEM  (errno)    -11         11
# We branch the constants so the rc→DnsError classification is correct on both.
comptime _EAI_NONAME: Int32 = (
    Int32(8) if CompilationTarget.is_macos() else Int32(-2)
)
comptime _EAI_AGAIN: Int32 = (
    Int32(2) if CompilationTarget.is_macos() else Int32(-3)
)
comptime _EAI_FAIL: Int32 = (
    Int32(4) if CompilationTarget.is_macos() else Int32(-4)
)
comptime _EAI_SYSTEM: Int32 = (
    Int32(11) if CompilationTarget.is_macos() else Int32(-11)
)

# struct addrinfo byte offsets. The struct is 48 bytes with ai_family @ +4 and
# ai_next @ +40 on BOTH platforms; the ONE difference is that BSD/Darwin SWAPS
# ai_canonname and ai_addr relative to glibc:
#
#   Linux x86_64 (glibc netdb.h):        BSD/Darwin (netdb.h):
#     int ai_flags;            @ 0  (4)    int ai_flags;            @ 0  (4)
#     int ai_family;           @ 4  (4)    int ai_family;           @ 4  (4)
#     int ai_socktype;         @ 8  (4)    int ai_socktype;         @ 8  (4)
#     int ai_protocol;         @ 12 (4)    int ai_protocol;         @ 12 (4)
#     socklen_t ai_addrlen;    @ 16 (4)    socklen_t ai_addrlen;    @ 16 (4)
#     (4 pad to align ptr)     @ 20        (4 pad to align ptr)     @ 20
#     struct sockaddr *ai_addr;@ 24 (8) <- char *ai_canonname;     @ 24 (8)  SWAP
#     char *ai_canonname;      @ 32 (8)    struct sockaddr *ai_addr;@ 32 (8)  SWAP
#     struct addrinfo *ai_next;@ 40 (8)    struct addrinfo *ai_next;@ 40 (8)
#   sizeof = 48 (both)                   sizeof = 48 (both)
#
# So ai_addr lives at +24 on Linux but +32 on macOS; ai_family (+4), ai_next
# (+40), and the struct size (48) are identical. We branch ONLY the ai_addr
# offset on platform.
comptime _AI_OFF_FAMILY: Int = 4
comptime _AI_OFF_ADDR: Int = 32 if CompilationTarget.is_macos() else 24
comptime _AI_OFF_NEXT: Int = 40
comptime _ADDRINFO_SIZE: Int = 48

# struct sockaddr_in byte offsets. sin_addr lives at +4 on BOTH platforms, but
# the LEADING fields differ — yet they sum to the same 4-byte prefix:
#   Linux (linux/in.h):                  BSD/Darwin (netinet/in.h):
#     sa_family_t sin_family; @ 0  (2)     __uint8_t   sin_len;    @ 0  (1)
#     __be16      sin_port;   @ 2  (2)     sa_family_t sin_family; @ 1  (1)
#     struct in_addr sin_addr;@ 4  (4)     in_port_t   sin_port;   @ 2  (2)
#                                          struct in_addr sin_addr;@ 4  (4)
# Either way sin_addr (the network-byte-order value we want) sits at +4, so a
# single offset constant is correct on both.
comptime _SIN_OFF_ADDR: Int = 4


# -----------------------------------------------------------------------------
# Address value types. They carry a `family` tag so IPv6 support
# follow-on is additive, not a signature break.
# -----------------------------------------------------------------------------


struct IpAddr(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """A resolved IP address. IPv4 only — `v4_be` holds the address in
    network byte order (the value the socket layer wants), `family` is always
    AF_INET (2). IPv6 support would add AF_INET6 + a 16-byte v6 field, read only when
    `family == AF_INET6`. POD — field-wise init: `IpAddr(family, v4_be)`."""

    var family: Int32  # AF_INET (2); AF_INET6 reserved for IPv6
    var v4_be: UInt32  # network-byte-order IPv4

    def __init__(out self, family: Int32, v4_be: UInt32):
        self.family = family
        self.v4_be = v4_be

    @always_inline
    def is_ipv4(self) -> Bool:
        return self.family == _AF_INET


struct SockAddr(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """An (IpAddr, port) pair — what a connect actually needs. `port` is host
    byte order (the socket layer's sockaddr_in_bytes converts to network byte
    order). POD — field-wise init: `SockAddr(ip, port)`."""

    var ip: IpAddr
    var port: UInt16

    def __init__(out self, ip: IpAddr, port: UInt16):
        self.ip = ip
        self.port = port


# -----------------------------------------------------------------------------
# IP-literal fast path — NEVER calls getaddrinfo; reactor-safe in
# every context. Consolidates pg's `_resolve_host_be` literal logic.
# -----------------------------------------------------------------------------


def parse_ip_literal(host: String) raises -> Optional[IpAddr]:
    """IP-LITERAL FAST PATH. Returns Some(IpAddr) if `host` is a loopback alias
    ("", "localhost", "127.0.0.1") or a dotted-quad IPv4 literal; None if `host`
    is NOT an IP literal (i.e. it needs DNS). Raises only on a *malformed*
    literal (octet > 255, wrong dot count, empty octet between dots).

    NEVER calls getaddrinfo. Allocation-light and reactor-safe everywhere.

    A "literal" here means: every character is a digit or a dot. Loopback
    aliases ("" / "localhost") short-circuit to 127.0.0.1 (kept for parity with
    pg's pre-DNS behavior + zero-dependency tests — KEEP). Any host
    containing a non-digit-non-dot character (e.g. a DNS name like
    `postgres.example.svc.cluster.local`) returns None → caller falls through to
    getaddrinfo. This is the behavioral change vs today: the old pg code RAISED
    on such names; now it returns None."""
    # Loopback aliases — exact-match shortcut.
    if (
        len(host.as_bytes()) == 0
        or host == String("localhost")
        or host == String("127.0.0.1")
    ):
        return Optional[IpAddr](IpAddr(_AF_INET, inet_loopback_be()))

    var b = host.as_bytes()
    # Classify: is every char digit-or-dot? If any other char appears, this is
    # NOT an IP literal → needs DNS → return None (NOT a raise).
    for i in range(len(b)):
        var ch = b[i]
        var is_digit = ch >= UInt8(ord("0")) and ch <= UInt8(ord("9"))
        var is_dot = ch == UInt8(ord("."))
        if not (is_digit or is_dot):
            return Optional[IpAddr]()  # None — needs DNS

    # Every char is digit-or-dot: it CLAIMS to be a dotted-quad literal, so a
    # malformed one RAISES (matches pg's old behavior exactly).
    var parts = List[Int]()
    var cur = 0
    var seen_digit = False
    for i in range(len(b)):
        var ch = b[i]
        if ch == UInt8(ord(".")):
            if not seen_digit:
                raise Error("dns: malformed IP literal '" + host + "'")
            parts.append(cur)
            cur = 0
            seen_digit = False
        else:
            cur = cur * 10 + Int(ch) - ord("0")
            seen_digit = True
    if seen_digit:
        parts.append(cur)
    if len(parts) != 4:
        raise Error("dns: malformed IPv4 literal '" + host + "'")
    for i in range(4):
        if parts[i] < 0 or parts[i] > 255:
            raise Error("dns: IPv4 octet out of range in '" + host + "'")
    # Network byte order: octet[0] is the high octet on the wire (big-endian);
    # inet_loopback_be returns 0x0100007F for 127.0.0.1, i.e. octets packed
    # little-end-first into the UInt32 so byte[0]==a. Match that packing exactly
    # (parity with pg's _resolve_host_be:137 and sockaddr_in_bytes).
    var packed = (
        UInt32(parts[0])
        | (UInt32(parts[1]) << 8)
        | (UInt32(parts[2]) << 16)
        | (UInt32(parts[3]) << 24)
    )
    return Optional[IpAddr](IpAddr(_AF_INET, packed))


# -----------------------------------------------------------------------------
# getaddrinfo FFI thunk — the ONLY code that touches `struct addrinfo`.
# -----------------------------------------------------------------------------


def _collect_a_records_from_addrinfo_list(
    head: UnsafePointer[UInt8, MutUntrackedOrigin],
) -> List[IpAddr]:
    """Walk a `struct addrinfo` linked list (starting at `head`) and return one
    `IpAddr` per AF_INET (A) record as a deep COPY (the bytes are read out of
    the libc-owned sockaddr_in into value `IpAddr`s; no pointer escapes).

    This is the PLATFORM-BRANCHED field-offset parser, factored out of
    `_getaddrinfo_collect` so it can be exercised hermetically by a unit test
    that hands it a hand-built byte layout (Linux OR macOS shape via the
    comptime offsets). The traversal reads:
      * ai_family @ +_AI_OFF_FAMILY (4, both platforms),
      * ai_addr   @ +_AI_OFF_ADDR  (24 Linux / 32 macOS) → sockaddr_in*,
      * sin_addr  @ +_SIN_OFF_ADDR (4, both platforms) — the 4 NBO bytes,
      * ai_next   @ +_AI_OFF_NEXT  (40, both platforms).

    # SAFETY:
    #   - `head` is a libc-OWNED (or, in the unit test, stack-local) addrinfo
    #     list. It is read-only here; no node is freed by this helper (the
    #     caller owns freeaddrinfo). The pointer has a CONCRETE origin
    #     (MutExternalOrigin — the FFI carve-out for genuinely-external memory),
    #     never built via unsafe_from_address=Int (the pointer rules).
    #   - Every node read is bounds-respecting per the struct layout; we follow
    #     ai_next until NULL. Each AF_INET node's 4 sin_addr bytes are COPIED
    #     into a value IpAddr appended to the returned List — nothing borrows
    #     the source memory past this call.
    """
    var out = List[IpAddr]()
    var node = head
    # MOJO-1.0.0: `Bool(ptr)` is gone (Pointer is non-null by design). `Int(p) != 0` is exactly what b2's `UnsafePointer.__bool__` computed.
    while Int(node) != 0:
        # ai_family @ +_AI_OFF_FAMILY (int).
        var fam = (node + _AI_OFF_FAMILY).bitcast[Int32]()[0]
        if fam == _AF_INET:
            # ai_addr @ +_AI_OFF_ADDR → sockaddr_in*; sin_addr @ +_SIN_OFF_ADDR
            # (4 bytes, already network byte order). Read into a UInt32 with the
            # same byte[0]==a packing as inet_loopback_be / parse_ip_literal.
            var sa = (node + _AI_OFF_ADDR).bitcast[
                UnsafePointer[UInt8, MutUntrackedOrigin]
            ]()[0]
            if Int(sa) != 0:
                var ab = sa + _SIN_OFF_ADDR
                var packed = (
                    UInt32(ab[0])
                    | (UInt32(ab[1]) << 8)
                    | (UInt32(ab[2]) << 16)
                    | (UInt32(ab[3]) << 24)
                )
                out.append(IpAddr(_AF_INET, packed))
        # ai_next @ +_AI_OFF_NEXT.
        node = (node + _AI_OFF_NEXT).bitcast[
            UnsafePointer[UInt8, MutUntrackedOrigin]
        ]()[0]
    return out^


def _getaddrinfo_collect(host: String, port: UInt16) raises -> List[IpAddr]:
    """Resolve `host` via getaddrinfo(3) and return one IpAddr per AF_INET (A)
    record, as a deep COPY (no glibc memory borrowed past this thunk).

    BLOCKING. Runs on the calling thread; never inside a reactor loop.

    # SAFETY:
    #   - The `addrinfo*` result list is glibc-OWNED and lives only until
    #     `freeaddrinfo(res)`. It is confined ENTIRELY to this thunk — no raw
    #     pointer escapes; the public surface returns `List[IpAddr]` by value.
    #   - The result-head local `res` is an `UnsafePointer[UInt8]` with the
    #     CONCRETE origin Mojo infers for a stack local (NOT a wildcard origin;
    #     the pointer rules) and is never built via `unsafe_from_address=Int` (hard
    #     ban #4). We pass `&res` to getaddrinfo via a 1-elem stack InlineArray
    #     of pointers, mirroring socket_setup.mojo's out-param style.
    #   - For each AF_INET node we read the 4 sin_addr bytes out of the
    #     glibc-owned sockaddr_in into a value `IpAddr` and APPEND it to the
    #     `List[IpAddr]` — copying the bytes so nothing borrows glibc memory.
    #   - `freeaddrinfo(res)` is called on EVERY exit path: we capture rc +
    #     collect the list, free, THEN branch on rc (free-then-raise). The
    #     freed pointer is never read again.
    """
    comptime if (
        not CompilationTarget.is_linux()
        and not CompilationTarget.is_macos()
    ):
        raise Error(
            "dns: getaddrinfo path is supported on Linux + macOS only"
            " (other platforms' addrinfo offsets are a portability follow-on)"
        )

    # Build the service string (decimal port). getaddrinfo accepts a NULL
    # service, but passing the port populates the hints correctly. We always
    # pass a non-null node (host) and a non-null service (port). `as_c_string_slice`
    # is a MUTATING method (NUL-terminates in place), so we materialize owned
    # mutable locals first — matches local_fs.mojo / glob.mojo. The C strings are
    # backed by THESE locals and outlive the external_call (which only reads).
    var host_local = host.copy()
    var service = String(Int(port))

    # hints: a 48-byte zeroed struct addrinfo with ai_family=AF_INET,
    # ai_socktype=SOCK_STREAM, ai_flags=AI_ADDRCONFIG. Stack-local; libc reads
    # only the int fields we set. The hint int-fields (ai_flags @ 0, ai_family
    # @ 4, ai_socktype @ 8) sit at IDENTICAL offsets on glibc + BSD/Darwin —
    # the layout difference is ONLY in the trailing pointer fields, which the
    # hints never set. The _AI_ADDRCONFIG value is the only platform-branched
    # input here (0x0020 glibc vs 0x0400 Darwin — handled by the constant).
    var hints = Array[UInt8, _ADDRINFO_SIZE](fill=UInt8(0))
    var hp = hints.unsafe_ptr()
    # ai_flags @ 0 (Int32)
    hp.bitcast[Int32]()[0] = _AI_ADDRCONFIG
    # ai_family @ 4 (Int32)
    (hp + _AI_OFF_FAMILY).bitcast[Int32]()[0] = _AF_INET
    # ai_socktype @ 8 (Int32)
    (hp + 8).bitcast[Int32]()[0] = _SOCK_STREAM

    # Result head out-param. getaddrinfo's `struct addrinfo **res` writes the
    # list head into res_slot[0]. `res_slot` is a 1-elem STACK-LOCAL InlineArray
    # (concrete stack storage; we pass `res_slot.unsafe_ptr()` as the **res
    # out-param, NOT unsafe_from_address=Int — the pointer rules). The ELEMENT type is
    # `UnsafePointer[UInt8, MutExternalOrigin]` because the addrinfo list it
    # points at is genuinely glibc-OWNED external memory — the FFI carve-out
    # (the same house style as
    # core/arrow/c_data_interface.mojo's C-ABI struct pointers). The wildcard-
    # origin BAN targets owning FIELDS on destroy-recreate structs (the destroy-recreate hazard); this
    # is a throwaway stack local confined to this FFI thunk + freed before
    # return, not a field.
    var res_slot = Array[UnsafePointer[UInt8, MutUntrackedOrigin], 1](
        fill=_null_ext_byte()
    )

    var c_host = host_local.as_c_string_slice().unsafe_ptr()
    var c_service = service.as_c_string_slice().unsafe_ptr()
    var rc = external_call["getaddrinfo", Int32](
        c_host,
        c_service,
        hp,
        res_slot.unsafe_ptr(),
    )

    var res = res_slot[0]

    # Walk the list FIRST (only valid when rc == 0; on error res is unmodified /
    # NULL). We collect, then free, then branch — so freeaddrinfo runs on every
    # path including the raise path below. The walk is factored into
    # `_collect_a_records_from_addrinfo_list` so the platform-branched field
    # offsets are exercised hermetically by a unit test (it builds a known
    # addrinfo byte layout and asserts the parsed family / sin_addr).
    var out = List[IpAddr]()
    if rc == Int32(0):
        out = _collect_a_records_from_addrinfo_list(res)

    # Free on EVERY path (only if getaddrinfo actually allocated a list).
    if rc == Int32(0) and Int(res) != 0:
        external_call["freeaddrinfo", NoneType](res)

    # Branch on rc AFTER the free (free-then-raise — Mojo has no defer).
    if rc != Int32(0):
        if rc == _EAI_NONAME:
            raise Error(
                "DnsError[NXDOMAIN]: no such host '" + host
                + "' (EAI_NONAME)"
            )
        elif rc == _EAI_AGAIN:
            raise Error(
                "DnsError[TRANSIENT]: temporary failure resolving '" + host
                + "' (EAI_AGAIN)"
            )
        else:
            raise Error(
                "DnsError[RESOLVE_FAILED]: getaddrinfo('" + host
                + "') failed (EAI=" + String(Int(rc)) + ")"
            )

    if len(out) == 0:
        raise Error(
            "DnsError[NO_IPV4_RECORD]: host '" + host
            + "' has no IPv4 (A) record"
        )

    return out^


# -----------------------------------------------------------------------------
# Public resolver surface.
# -----------------------------------------------------------------------------


def resolve_host(host: String, port: UInt16) raises -> List[SockAddr]:
    """Resolve `host` to a list of connect targets for `port`.

    1. Try parse_ip_literal(host). If Some → return [SockAddr(literal, port)]
       WITHOUT calling getaddrinfo (preserves today's behavior exactly + zero
       DNS latency for IP-literal hosts).
    2. Otherwise call getaddrinfo (BLOCKING — must run on the calling thread,
       never on a per-core reactor thread). Return one SockAddr per A record
       (AF_INET only).

    Raises DnsError on NXDOMAIN / transient / failure / no A records.
    Callers pick an address from the list."""
    var lit = parse_ip_literal(host)
    if lit:
        var out = List[SockAddr]()
        out.append(SockAddr(lit.value(), port))
        return out^

    var addrs = _getaddrinfo_collect(host, port)
    var targets = List[SockAddr]()
    for i in range(len(addrs)):
        targets.append(SockAddr(addrs[i], port))
    return targets^


def resolve_host_be(host: String, port: UInt16) raises -> UInt32:
    """Convenience: resolve and return the FIRST A record's network-byte-order
    IPv4 (the `ip_be` the socket layer wants). Equals
    `resolve_host(host, port)[0].ip.v4_be`. The DIRECT drop-in for
    `pg_tls._resolve_host_be` (and http's `_ip_be_from_host`):
    same return type (UInt32), same call shape.

    Raises if no IPv4 (A) record is available."""
    var targets = resolve_host(host, port)
    # resolve_host raises before returning an empty list (literal always Some;
    # getaddrinfo raises NO_IPV4_RECORD on empty) — but guard defensively.
    if len(targets) == 0:
        raise Error(
            "DnsError[NO_IPV4_RECORD]: host '" + host
            + "' produced no connect target"
        )
    return targets[0].ip.v4_be
