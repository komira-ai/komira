# =============================================================================
# tests/test_keychain_secret_store.mojo: `KeychainSecretStore` over the
#   in-memory `StaticKeychainBackend`, plus the pure helpers.
# =============================================================================
#
# No test starts a process or reads a keychain. The macOS backend's `fetch` is
# called only where it cannot spawn: on a platform other than macOS it answers an
# error lookup, which the test asserts; on macOS the test does not call it, so
# the `security` tool never runs.
#
#   * resolve returns the scripted bytes exactly (and a service-only ref
#     resolves with an empty account);
#   * a miss, a backend error and an empty service each raise, and no error
#     carries the secret;
#   * the backend is queried with the parsed service and account;
#   * the ref parser, the `security` argv builder, the stdout newline strip and
#     the stderr tail bound;
#   * the three KeychainLookup outcomes are exclusive.
# =============================================================================

from std.sys.info import CompilationTarget

from std.testing import assert_equal, assert_true, assert_false


from komira_secrets_keychain.keychain_backend import (
    StaticKeychainBackend,
    KeychainLookup,
)
from komira_secrets_keychain.keychain_secret_store import (
    KeychainSecretStore,
    parse_keychain_ref,
)
from komira_secrets_keychain.macos_security_backend import (
    MacosSecurityKeychainBackend,
    build_security_argv,
    _bounded_tail,
    map_security_result,
    _stdout_to_secret_bytes,
)


# =============================================================================
# Fixtures.
# =============================================================================
comptime _SERVICE: String = "komira-local-pg"
comptime _ACCOUNT: String = "app"
comptime _REF: String = "komira-local-pg/app"
# A realistic Postgres connection string (special chars the byte path must keep).
comptime _SECRET: String = (
    "postgresql://app:pw-w0rd@db.example.test:5432/app?sslmode=require"
)


def _backend_with_canned() -> StaticKeychainBackend:
    """A StaticKeychainBackend scripted with the canned `(service, account) ->
    secret` so `resolve(_REF)` finds it."""
    var b = StaticKeychainBackend()
    b.put(String(_SERVICE), String(_ACCOUNT), String(_SECRET))
    return b^


# =============================================================================
# (a) RESOLVE round-trip — a scripted ref returns the canned bytes.
# =============================================================================
def test_resolve_returns_canned_bytes() raises:
    """`resolve(_REF)` over a scripted backend returns a SecretValue whose bytes
    equal the canned secret, byte-for-byte."""
    var store = KeychainSecretStore[StaticKeychainBackend](
        _backend_with_canned()
    )
    var sv = store.resolve(String(_REF))

    var expected = String(_SECRET).as_bytes()
    assert_equal(sv.len(), len(expected), "resolved length == secret length")
    var bytes = sv.revealed_bytes()
    for i in range(len(expected)):
        assert_equal(bytes[i], expected[i], "resolved byte matches the secret")
    _ = sv^
    _ = store^


def test_resolve_service_only_ref() raises:
    """A service-only ref (no '/') resolves when the backend scripted it with an
    EMPTY account — the keychain-matches-on-service-alone path."""
    var b = StaticKeychainBackend()
    b.put(String("svc-only"), String(""), String("the-value"))
    var store = KeychainSecretStore[StaticKeychainBackend](b^)
    var sv = store.resolve(String("svc-only"))
    assert_equal(sv.len(), len(String("the-value").as_bytes()), "len matches")
    _ = sv^
    _ = store^


# =============================================================================
# (b) FAIL-FAST — a MISS and a backend ERROR each RAISE.
# =============================================================================
def test_resolve_missing_entry_raises() raises:
    """A `resolve` of a ref the backend does not have (a MISS) RAISES — never a
    silent stale / empty value. The error names the ref but NOT a secret."""
    # An empty backend: every fetch is a miss.
    var store = KeychainSecretStore[StaticKeychainBackend](
        StaticKeychainBackend()
    )
    var raised = False
    try:
        var sv = store.resolve(String("absent-svc/absent-acct"))
        _ = sv^
    except e:
        raised = True
        var msg = String(e)
        assert_true(
            msg.find(String("absent-svc")) >= 0, "the error names the ref"
        )
        assert_false(
            msg.find(String(_SECRET)) >= 0, "the error carries NO secret"
        )
    assert_true(raised, "a missing entry raises (fail fast and loud)")
    _ = store^


def test_resolve_backend_error_raises() raises:
    """A backend ERROR (keychain locked / CLI failed) RAISES with the backend's
    NON-secret reason — distinct from a clean miss."""
    var b = StaticKeychainBackend()
    b.put_error(
        String("locked-svc"), String("acct"), String("keychain is locked")
    )
    var store = KeychainSecretStore[StaticKeychainBackend](b^)
    var raised = False
    try:
        var sv = store.resolve(String("locked-svc/acct"))
        _ = sv^
    except e:
        raised = True
        var msg = String(e)
        assert_true(
            msg.find(String("keychain is locked")) >= 0,
            "the error carries the backend reason",
        )
    assert_true(raised, "a backend error raises")
    _ = store^


def test_resolve_empty_service_raises() raises:
    """A ref with an empty service (a leading '/' or empty ref) RAISES BEFORE any
    backend query — never query the keychain with no service."""
    var store = KeychainSecretStore[StaticKeychainBackend](
        StaticKeychainBackend()
    )
    var raised = False
    try:
        var sv = store.resolve(String("/just-account"))
        _ = sv^
    except e:
        raised = True
    assert_true(raised, "an empty-service ref raises")
    _ = store^


# =============================================================================
# (c) The backend is QUERIED with the PARSED service/account.
# =============================================================================
def test_backend_queried_with_parsed_service_account() raises:
    """After `resolve("svc/acct")`, the recording double was queried with
    service=="svc" + account=="acct" (the store PARSED the ref + queried the
    keychain with the right names). Uses a `share()`-free read via a found path
    plus a re-fetch of the SAME backend through a second store handle. Here we
    instead drive the backend DIRECTLY after the store resolve by reading its
    recorder — so we resolve over a backend we keep a reference to via re-build.

    We assert through a backend the store consumes: build the store, resolve,
    then assert on a FRESH parse of the ref to confirm the store's parse matches
    what the backend would have been queried with. (The StaticKeychainBackend is
    moved into the store, so we verify the parse contract on the pure parser AND
    via a separate recording backend driven through its own store.)"""
    # Drive a recording backend through the store, then read the recorder. The
    # backend is moved into the store; to read its recorder after the move we
    # resolve, then assert via the pure parser that the store's parse of _REF is
    # (svc, acct) — the exact names the backend.fetch receives.
    var store = KeychainSecretStore[StaticKeychainBackend](
        _backend_with_canned()
    )
    var sv = store.resolve(String(_REF))
    assert_true(sv.len() > 0, "the resolve found the scripted entry")
    _ = sv^
    _ = store^

    # The parse the store performed maps _REF -> (_SERVICE, _ACCOUNT), which is
    # exactly what fetch(service, account) received (the found path proves the
    # backend matched on those names — an empty backend would have missed).
    var parsed = parse_keychain_ref(String(_REF))
    assert_equal(parsed.service, String(_SERVICE), "parsed service == svc")
    assert_equal(parsed.account, String(_ACCOUNT), "parsed account == acct")


def test_static_backend_records_query() raises:
    """The StaticKeychainBackend double records the LAST queried (service,
    account) + a query count — the recorder the store gate relies on. Driven
    DIRECTLY (no store) so we can read the recorder after the fetch."""
    var b = StaticKeychainBackend()
    b.put(String(_SERVICE), String(_ACCOUNT), String(_SECRET))
    assert_equal(b.query_count(), 0, "no query yet")

    var lookup = b.fetch(String(_SERVICE), String(_ACCOUNT))
    assert_true(lookup.is_found(), "the scripted pair is found")
    assert_equal(b.last_service(), String(_SERVICE), "recorded service")
    assert_equal(b.last_account(), String(_ACCOUNT), "recorded account")
    assert_equal(b.query_count(), 1, "query count bumped")
    _ = lookup^

    # An un-scripted pair is a miss + still records.
    var miss = b.fetch(String("other"), String("nobody"))
    assert_true(miss.is_miss(), "an un-scripted pair misses")
    assert_equal(b.last_service(), String("other"), "recorded the miss service")
    assert_equal(b.query_count(), 2, "query count bumped again")
    _ = miss^
    _ = b^


# =============================================================================
# Pure helpers — the ref parser + the macOS argv builder (no spawn/no backend).
# =============================================================================
def test_parse_two_part_ref() raises:
    """`service/account` parses to (service, account)."""
    var p = parse_keychain_ref(String("svc/acct"))
    assert_equal(p.service, String("svc"), "service")
    assert_equal(p.account, String("acct"), "account")


def test_parse_service_only_ref() raises:
    """`service` (no '/') parses to (service, empty-account)."""
    var p = parse_keychain_ref(String("just-svc"))
    assert_equal(p.service, String("just-svc"), "service")
    assert_equal(p.account, String(""), "empty account")


def test_parse_account_with_slash() raises:
    """The FIRST '/' separates; an account may itself contain '/'."""
    var p = parse_keychain_ref(String("svc/a/c/c/t"))
    assert_equal(p.service, String("svc"), "service is up to the FIRST slash")
    assert_equal(p.account, String("a/c/c/t"), "account keeps later slashes")


def test_parse_keeps_non_ascii_names() raises:
    """A non-ASCII service or account reaches the backend unchanged (one byte
    is not one character)."""
    var p = parse_keychain_ref(String("café/àccount"))
    assert_equal(p.service, String("café"), "non-ASCII service")
    assert_equal(p.account, String("àccount"), "non-ASCII account")
    var only = parse_keychain_ref(String("naïve"))
    assert_equal(only.service, String("naïve"), "non-ASCII service-only ref")
    var b = StaticKeychainBackend()
    b.put(String("café"), String("àccount"), String("v"))
    var store = KeychainSecretStore[StaticKeychainBackend](b^)
    var sv = store.resolve(String("café/àccount"))
    assert_equal(sv.len(), 1, "resolved through the non-ASCII names")
    _ = sv^
    _ = store^


def test_parse_empty_service_raises() raises:
    """A leading '/' (empty service) RAISES."""
    var raised = False
    try:
        var p = parse_keychain_ref(String("/acct"))
        _ = p
    except e:
        raised = True
    assert_true(raised, "empty service raises")


def test_build_security_argv_two_part() raises:
    """The argv for a (service, account) lookup is `find-generic-password -s
    <service> -a <account> -w`."""
    var argv = build_security_argv(String("svc"), String("acct"))
    assert_equal(len(argv), 6, "six argv entries")
    assert_equal(argv[0], String("find-generic-password"), "subcommand")
    assert_equal(argv[1], String("-s"), "-s flag")
    assert_equal(argv[2], String("svc"), "service")
    assert_equal(argv[3], String("-a"), "-a flag")
    assert_equal(argv[4], String("acct"), "account")
    assert_equal(argv[5], String("-w"), "-w (password-only) flag")


def test_build_security_argv_service_only() raises:
    """A service-only lookup OMITS the `-a` flag (security matches on service)."""
    var argv = build_security_argv(String("svc"), String(""))
    assert_equal(len(argv), 4, "four argv entries (no -a)")
    assert_equal(argv[0], String("find-generic-password"), "subcommand")
    assert_equal(argv[1], String("-s"), "-s flag")
    assert_equal(argv[2], String("svc"), "service")
    assert_equal(argv[3], String("-w"), "-w flag")


# =============================================================================
# KeychainLookup — the three-outcome value POD.
# =============================================================================
def test_keychain_lookup_outcomes() raises:
    """The three KeychainLookup factories produce mutually-exclusive states."""
    var found_bytes = List[UInt8]()
    found_bytes.append(UInt8(ord("x")))
    var found = KeychainLookup.found(found_bytes^)
    assert_true(found.is_found(), "found")
    assert_false(found.is_miss(), "not miss")
    assert_false(found.is_error(), "not error")
    _ = found^

    var miss = KeychainLookup.miss()
    assert_true(miss.is_miss(), "miss")
    assert_false(miss.is_found(), "not found")
    _ = miss^

    var err = KeychainLookup.error(String("boom"))
    assert_true(err.is_error(), "error")
    assert_equal(err.error_reason, String("boom"), "carries the reason")
    assert_false(err.is_found(), "not found")
    _ = err^


# =============================================================================
# The macOS backend's pure pieces and its platform gate.
# =============================================================================
def test_stdout_strips_exactly_one_newline() raises:
    """`security -w` prints `<password>\\n`: one trailing newline (and a
    preceding carriage return) is the CLI's, anything more is the password's."""
    var plain = _stdout_to_secret_bytes(String("pw\n"))
    assert_equal(len(plain), 2, "one newline stripped")
    var crlf = _stdout_to_secret_bytes(String("pw\r\n"))
    assert_equal(len(crlf), 2, "CRLF stripped as one terminator")
    var two = _stdout_to_secret_bytes(String("pw\n\n"))
    assert_equal(len(two), 3, "only one of two newlines is the CLI's")
    var bare = _stdout_to_secret_bytes(String("pw"))
    assert_equal(len(bare), 2, "no terminator, nothing stripped")
    var lone_cr = _stdout_to_secret_bytes(String("pw\r"))
    assert_equal(len(lone_cr), 3, "a CR without a LF is the password's")
    var empty = _stdout_to_secret_bytes(String(""))
    assert_equal(len(empty), 0, "empty stdout")
    var only_nl = _stdout_to_secret_bytes(String("\n"))
    assert_equal(len(only_nl), 0, "a bare newline is an empty password")


def test_bounded_tail_trims_and_bounds() raises:
    """The stderr tail drops trailing whitespace and keeps at most the last 200
    bytes."""
    assert_equal(_bounded_tail(String("oops \n\t\r")), String("oops"), "trimmed")
    var long = String("")
    for _ in range(300):
        long += "a"
    long += "TAIL"
    var tail = _bounded_tail(long)
    assert_equal(len(tail.as_bytes()), 200, "bounded to 200 bytes")
    assert_true(tail.as_bytes()[196] == UInt8(ord("T")), "keeps the END")
    assert_equal(_bounded_tail(String("   ")), String(""), "all blank")


def test_bounded_tail_keeps_non_ascii() raises:
    """Diagnostics are UTF-8: a tail that starts inside a character skips to the
    next boundary instead of re-encoding each byte (one byte is not one
    character), and a short non-ASCII message comes back as it is."""
    assert_equal(
        _bounded_tail(String("clé introuvable\n")),
        String("clé introuvable"),
        "short non-ASCII message unchanged",
    )
    var long = String("a")
    for _ in range(150):
        long += "é"
    long += "b"  # 302 bytes; the 200-byte window starts mid-character
    var want = String("")
    for _ in range(99):
        want += "é"
    want += "b"
    assert_equal(_bounded_tail(long), want, "window starts at a boundary")


def test_map_security_result_exit_codes() raises:
    """Every exit class of `security find-generic-password -w`, with no process:
    0 is found (one newline stripped), 44 is a miss, anything else an error with
    the code and a bounded stderr tail, and stdout (the secret) never reaches an
    error."""
    var out = String("hunter2\n")
    var err = String("")
    var found = map_security_result(0, out, err)
    assert_true(found.is_found(), "exit 0 is found")
    assert_equal(len(found.bytes), 7, "the CLI's newline is stripped")
    assert_equal(out, String(""), "stdout dropped")

    var out44 = String("SECRET-IN-STDOUT")
    var err44 = String("The specified item could not be found in the keychain.\n")
    assert_true(map_security_result(44, out44, err44).is_miss(), "44 is a miss")

    var out36 = String("SECRET-IN-STDOUT")
    var err36 = String("User interaction is not allowed.\n")
    var locked = map_security_result(36, out36, err36)
    assert_true(locked.is_error(), "36 is an error")
    assert_equal(
        locked.error_reason,
        String("/usr/bin/security exited 36: User interaction is not allowed."),
        "code and stderr tail",
    )
    assert_true(locked.error_reason.find(String("SECRET")) < 0, "no stdout in the error")

    var out128 = String("SECRET-IN-STDOUT")
    var err128 = String("")
    var cancelled = map_security_result(128, out128, err128)
    assert_equal(
        cancelled.error_reason,
        String("/usr/bin/security exited 128"),
        "no stderr, no colon",
    )
    assert_true(cancelled.error_reason.find(String("SECRET")) < 0, "no stdout")

    var out1 = String("pw")
    var err1 = String("x")
    assert_true(map_security_result(1, out1, err1).is_error(), "1 is an error")
    var outm = String("pw")
    var errm = String("")
    assert_true(map_security_result(-1, outm, errm).is_error(), "a signal-style code is an error")


def test_macos_backend_is_gated_by_platform() raises:
    """Off macOS, `fetch` answers an error lookup and starts no process. On
    macOS it is not called here: the test never runs the `security` tool."""
    comptime if not CompilationTarget.is_macos():
        var b = MacosSecurityKeychainBackend()
        var lookup = b.fetch(String("svc"), String("acct"))
        assert_true(lookup.is_error(), "not macOS: an error, no spawn")
        assert_true(
            lookup.error_reason.find(String("only available on macOS")) >= 0,
            "the reason says why",
        )
        var store = KeychainSecretStore[MacosSecurityKeychainBackend](b^)
        var raised = False
        try:
            var sv = store.resolve(String("svc/acct"))
            _ = sv^
        except e:
            raised = True
            assert_true(
                String(e).find(String("keychain backend failed")) >= 0,
                "the store reports a backend failure",
            )
        assert_true(raised, "resolve through the gated backend raises")
        _ = store^


def main() raises:
    # (a) resolve round-trip
    test_resolve_returns_canned_bytes()
    test_resolve_service_only_ref()
    # (b) fail-fast
    test_resolve_missing_entry_raises()
    test_resolve_backend_error_raises()
    test_resolve_empty_service_raises()
    # (c) backend queried with parsed service/account
    test_backend_queried_with_parsed_service_account()
    test_static_backend_records_query()
    # pure helpers
    test_parse_two_part_ref()
    test_parse_service_only_ref()
    test_parse_account_with_slash()
    test_parse_keeps_non_ascii_names()
    test_parse_empty_service_raises()
    test_build_security_argv_two_part()
    test_build_security_argv_service_only()
    test_keychain_lookup_outcomes()
    test_stdout_strips_exactly_one_newline()
    test_bounded_tail_trims_and_bounds()
    test_bounded_tail_keeps_non_ascii()
    test_map_security_result_exit_codes()
    test_macos_backend_is_gated_by_platform()
    print("PASS test_keychain_secret_store")
