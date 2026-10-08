from std.ffi import external_call

comptime S2N_TLS13: Int32 = 34


def expect(ok: Bool, what: String) raises:
    if not ok:
        raise Error("test_s2n_handshake: " + what)


def main() raises:
    """s2n-tls over aws-lc: initialise s2n from Mojo, then a TLS 1.3 handshake
    (handshake.c) between a client and a server in this process."""
    expect(external_call["komira_s2n_init", Int32]() == 0, "s2n_init failed")
    print("s2n_init: ok")
    var version = List[Int32](length=1, fill=0)
    expect(external_call["komira_s2n_handshake", Int32](version.unsafe_ptr()) == 0, "the handshake failed (see stderr)")
    expect(version[0] == S2N_TLS13, "negotiated protocol " + String(version[0]) + ", not TLS 1.3")
    print("handshake: TLS 1.3, certificate verified, ping/pong exchanged")
    expect(external_call["komira_s2n_cleanup", Int32]() == 0, "s2n_cleanup failed")
