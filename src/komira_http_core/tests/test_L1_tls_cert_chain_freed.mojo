"""`TlsConfig.load_cert` frees the cert chain it allocates when the config
drops (komira#886).

`load_cert` attaches its chain with `s2n_config_add_cert_chain_and_key_to_store`,
which marks the config's chains application-owned; `s2n_config_free` then
frees none of them (tls/s2n_config.c, `s2n_config_free_cert_chain_and_key`
returns early). The config handle must free each chain itself.

Each case builds and drops a config many times and reads the process's
resident set (VmRSS in /proc/self/status) after a warm-up and at the end. A
chain holds the parsed certificate, the RSA 2048 private key and s2n's own
structs, several KiB, so a chain left behind on every round grows the
resident set by megabytes over the rounds below; freed chains let the
allocator reuse the same memory and the resident set stays put. s2n
allocates its own structs in mlock'd pages by default, so leaked chains can
also exhaust the locked-memory limit first: `s2n_cert_chain_and_key_new`
then returns NULL and the round that hit it is named in the failure.

  * test_loaded_chain_freed: `load_cert` succeeds, the config drops. This is
    the leak #886 reports: every loaded chain stayed allocated.
  * test_refused_chain_freed: s2n refuses the chain for the config (the
    rfc9151 policy forbids an RSA 2048 key) after it parsed. The config
    handle keeps such a chain until the config drops, because s2n may already
    hold the pointer in its SNI map; this case shows it is freed then.
"""

from std.pathlib import Path

from komira_http_core.tls import TlsConfig, tls_init


comptime _FIXTURES = "src/komira_http_core/tests/fixtures/tls/"
# Rounds before the first reading: the allocator and s2n's lazily built
# state settle here.
comptime _WARMUP = 200
comptime _ROUNDS = 2000
# Growth allowed between the two readings. A leaked chain per round is far
# over this (several KiB x 2000 rounds); the readings print either way.
comptime _MAX_GROWTH_KIB = 1024


def _kib(text: String, key: String) raises -> Int:
    """The `<key> <n> kB` value of a /proc/self/status text."""
    var i = text.find(key)
    if i < 0:
        raise Error("/proc/self/status has no " + key)
    var b = text.as_bytes()
    var j = i + key.byte_length()
    while j < len(b) and (b[j] == 32 or b[j] == 9):
        j += 1
    var v = 0
    while j < len(b) and b[j] >= 48 and b[j] <= 57:
        v = v * 10 + Int(b[j] - 48)
        j += 1
    return v


def _status_kib(key: String) raises -> Int:
    with open("/proc/self/status", "r") as f:
        return _kib(f.read(), key)


def _load_and_drop(cert: String, key: String) raises:
    var config = TlsConfig()
    config.load_cert(cert, key)


def _refuse_and_drop(cert: String, key: String) raises:
    var config = TlsConfig()
    config.set_cipher_preferences(String("rfc9151"))
    try:
        config.load_cert(cert, key)
    except e:
        if "s2n_config_add_cert_chain_and_key_to_store failed" not in String(e):
            raise e^
        return
    raise Error("RSA 2048 certificate accepted under rfc9151")


def _check_growth(name: String, before: Int, after: Int) raises:
    var growth = after - before
    print(
        "    " + name + ": VmRSS " + String(before) + " kB -> "
        + String(after) + " kB over " + String(_ROUNDS - _WARMUP)
        + " rounds (growth " + String(growth) + " kB, limit "
        + String(_MAX_GROWTH_KIB) + "); VmLck "
        + String(_status_kib("VmLck:")) + " kB"
    )
    if growth > _MAX_GROWTH_KIB:
        raise Error(
            name + ": resident set grew " + String(growth) + " kB over "
            + String(_ROUNDS - _WARMUP)
            + " config drops; the cert chains were not freed"
        )


def _round(refuse: Bool, i: Int, cert: String, key: String) raises:
    try:
        if refuse:
            _refuse_and_drop(cert, key)
        else:
            _load_and_drop(cert, key)
    except e:
        raise Error("round " + String(i) + " of " + String(_ROUNDS) + ": " + String(e))


def _rounds(name: String, refuse: Bool, cert: String, key: String) raises:
    for i in range(_WARMUP):
        _round(refuse, i, cert, key)
    var before = _status_kib("VmRSS:")
    for i in range(_WARMUP, _ROUNDS):
        _round(refuse, i, cert, key)
    _check_growth(name, before, _status_kib("VmRSS:"))


def test_loaded_chain_freed(cert: String, key: String) raises:
    print("  test_loaded_chain_freed...")
    _rounds("loaded", False, cert, key)


def test_refused_chain_freed(cert: String, key: String) raises:
    print("  test_refused_chain_freed...")
    _rounds("refused", True, cert, key)


def main() raises:
    print("== L1 TLS cert chain freed with its config ==")
    tls_init()
    var cert = Path(_FIXTURES + "leaf_cert.pem").read_text()
    var key = Path(_FIXTURES + "leaf_key.pem").read_text()
    test_loaded_chain_freed(cert, key)
    test_refused_chain_freed(cert, key)
    print("PASS")
