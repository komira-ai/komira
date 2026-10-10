"""The s2n refusals of `tls/s2n_shim.mojo` that need a process whose s2n state
no other test may share: s2n not yet initialised, then initialised behind the
shim's back. One process, in this order:

  1. Before `s2n_init`, s2n's allocator refuses every allocation
     (S2N_ERR_NOT_INITIALIZED, utils/s2n_mem.c), so `s2n_config_new`,
     `s2n_connection_new` and `s2n_cert_chain_and_key_new` return NULL: the
     handles' `create` and `load_cert` raise naming the NULL, and the
     handles they leave behind are dropped with their null sentinel (no
     free of NULL).
  2. `s2n_init` is called directly, as a foreign library sharing the process
     would. The shim's own init-once then gets S2N_ERR_INITIALIZED from its
     `s2n_init`: `tls_init` raises with the code, `TlsConfig()` raises the
     same, and so does a second `tls_init` (the code is kept; s2n_init is not
     run again).
  3. s2n is initialised, so `_S2nConfigHandle.create` now succeeds: the
     refusals in 1 were the init state, not the call.
"""

from std.memory import ArcPointer
from std.pathlib import Path

from komira_http_core.tls import TlsConfig, last_s2n_errno, tls_init
from komira_http_core.tls.ffi import S2N_SERVER, s2n_init
from komira_http_core.tls.s2n_shim import _S2nConfigHandle, _S2nConnectionHandle


comptime _FIXTURES = "src/komira_http_core/tests/fixtures/tls/"


def _expect_raise_has(e: Error, needle: String, what: String) raises:
    var msg = String(e)
    if msg.find(needle) < 0:
        raise Error(what + ": raised '" + msg + "', expected it to contain '" + needle + "'")


def test_refused_before_init() raises:
    print("  test_refused_before_init...")
    try:
        var _h = _S2nConfigHandle.create()
        raise Error("s2n_config_new succeeded before s2n_init")
    except e:
        _expect_raise_has(e, "_S2nConfigHandle.create: s2n_config_new returned NULL", "config")
    try:
        var _h = _S2nConnectionHandle.create(S2N_SERVER)
        raise Error("s2n_connection_new succeeded before s2n_init")
    except e:
        _expect_raise_has(e, "_S2nConnectionHandle.create: s2n_connection_new returned NULL", "connection")
    var config = TlsConfig(_handle=ArcPointer[_S2nConfigHandle](_S2nConfigHandle()))
    try:
        config.load_cert(
            Path(_FIXTURES + "leaf_cert.pem").read_text(),
            Path(_FIXTURES + "leaf_key.pem").read_text(),
        )
        raise Error("s2n_cert_chain_and_key_new succeeded before s2n_init")
    except e:
        _expect_raise_has(e, "TlsConfig.load_cert: s2n_cert_chain_and_key_new returned NULL", "cert chain")
    print("    OK")


def test_init_refused_after_foreign_init() raises:
    print("  test_init_refused_after_foreign_init...")
    var rc = s2n_init()
    if rc != Int32(0):
        raise Error("the direct s2n_init returned " + String(Int(rc)))
    var want = String("tls_init: s2n_init returned -1 (errno=")
    try:
        tls_init()
        raise Error("tls_init succeeded over an initialised s2n")
    except e:
        _expect_raise_has(e, want, "first tls_init")
    if last_s2n_errno() == Int32(0):
        raise Error("no s2n errno after the refused s2n_init")
    try:
        var _c = TlsConfig()
        raise Error("TlsConfig() succeeded after tls_init failed")
    except e:
        _expect_raise_has(e, want, "TlsConfig()")
    try:
        tls_init()
        raise Error("a second tls_init succeeded")
    except e:
        _expect_raise_has(e, want, "second tls_init")
    var _live = _S2nConfigHandle.create()
    print("    OK")


def main() raises:
    print("== L1 TLS init refused ==")
    test_refused_before_init()
    test_init_refused_after_foreign_init()
    print("== L1 TLS init refused PASSED (2 tests) ==")
