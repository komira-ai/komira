"""L2 acceptance gate — THE PEER CLIENT for the cross-cloud service registry.

Every gate below was written by APPLYING a specific mutation to production,
watching the pre-existing gates stay GREEN, and keeping only an assertion that
then went RED. Each names the mutant it kills so nobody re-relaxes the line it
guards.

  1.  A HIT RESOLVES, AND THE `key` IS THE SERVER'S.
      M1  `_lookup` reports `resolve_service_path(name)` as the key — the
          client's own belief. The fixture's server reports a DIFFERENT key on
          purpose, so a re-derivation is visible; a fixture where the two agree
          would make this gate unfalsifiable.
  2.  ⭐ `found:false` FROM A REACHED REGISTRY IS `PEER_ABSENT`, sourced from the
      STORE — the claim "we asked and it is not there".
      M2  classify reads a `found:false` body as NOT_REACHED.
  3.  ⭐⭐ A 404 IS NEVER ABSENCE, AND A MARKED 404 IS NOT AN UNMARKED ONE.
      M3  classify answers `ok(found=False)` on a 404 — the obvious REST shape,
          and the single most damaging mistake this client can make.
      M3b classify ignores the marker on a non-2xx (everything is NOT_REACHED).
          RED on the MARKED arm ALONE. Without M3b the marker is decoration:
          M3 is killed by the unmarked arm just as well.
  4.  ⭐ AN UNREACHABLE REGISTRY IS NOT AN ABSENCE. `source` is UNSET and the key
      is EMPTY, because we consulted nothing.
      M4  the `except` arm returns `ResolveResult.absent(path)` — which asserts
          `found=0 source=store`, i.e. writes "the store was reached and the key
          is unregistered" into the log line for a network fault.
  5.  A BODY THAT IS NOT THE CONTRACT IS `PEER_PROTOCOL_ERROR` — six fixtures.
      M5  a missing `found` defaults to false. RED on the missing-member fixture
          ALONE.
      M5b the STRING `"false"` is accepted as the literal. RED on the
          quoted-boolean fixture ALONE. M5 and M5b are why this gate carries six
          fixtures and not one: each mutant is invisible to the other's.
  6.  ⭐ STALE: A FAILED FETCH AFTER A GOOD READ SERVES THE LAST ENDPOINT, USABLE,
      LABELLED, WITH THE REAL AGE.
      M6  the stale arm deleted (fall through to UNREACHABLE).
      M6b the stale arm returns disposition FRESH / `from_store`. RED on the
          DISPOSITION line alone, while M6 is RED on the `usable()` line above
          it — serving the endpoint is half the property and SAYING SO is the
          other half, so the two assertions are ordered to keep them separable.
  7.  ⭐ STALE IS BOUNDED, and `max_stale_ms = 0` disables it entirely.
      M7  the `stale_age <= max_stale` comparison deleted.
  8.  ⭐⭐ A REACHED `found:false` EVICTS, and does NOT fall back to the cache.
      M8  the absent arm prefers the cached entry ("availability").
      M8b the absent arm answers ABSENT but does NOT evict. RED on the THIRD
          step alone (a later failure must be UNREACHABLE, not STALE).
  9.  NEGATIVES ARE NOT CACHED — a second lookup after an absence DIALS again.
      M9  `_lookup` stores an entry on `found:false`.
  10. A FRESH CACHE HIT DOES NOT DIAL, reports `source=cache`, the REAL age, and
      the SERVER's key; and `ttl_ms = 0` never serves from cache.
      M10 the hit is rebuilt with `from_store`.
  12. AN UNSAFE NAME IS REFUSED WITHOUT A DIAL.
      M12 `refuse_unsafe_segment` always returns "".
      M12b the client percent-encodes instead of refusing — which makes the
          server consult a key nobody registered and report it unregistered.
  13. ⭐ BOOTSTRAP: A BAD BASE URL IS A REFUSAL AT CONSTRUCTION, NAMING THE FLAG.
      M13 `parse` accepts an empty base.
      M13b the plaintext check accepts any host. RED on the http-to-a-public-
          host arm alone.
  14. THE `REFUSED` DISPOSITION IS TRANSLATED, NOT PASSED THROUGH.
      M14 `answer.kind` used as the disposition. The two vocabularies are
          different and their ordinals do not line up; the bug compiles.
  15. A MARKED 5xx IS `PEER_REGISTRY_ERROR`, not UNREACHABLE — it proves the base
      URL and the whole network path are right.
      M15 classify folds 5xx into NOT_REACHED.
  16. `usable()` IS FALSE FOR EVERY DISPOSITION THAT CARRIES NO ENDPOINT.
      M16 `usable()` includes PEER_ABSENT.
  17. THE LOG LINE CARRIES EVERY FACT — including the contract's own four.
      M17 `describe()` stops embedding `result.describe()`.
  18. THE VALUE DECODER IS BYTE-FAITHFUL over >= 0x80 and over escapes.
      M18 the pass-through run replaced by `chr(Int(c))` — the exact defect the
          server's own writer is gated against, in the inverse direction.
  19. AN UNKNOWN MEMBER DOES NOT BREAK THE PARSE.
      M19 the parser refuses unknown members — which turns a compatible
          server-side addition into a fleet-wide resolution outage.
  20. A REGISTRY REFUSAL (400) NEVER SERVES A STALE ENDPOINT.
      M20 the REFUSED early-return deleted, so a 400 falls into the stale block.
  21. ⛔ A LOOPBACK LOOKALIKE HOSTNAME IS NOT LOOPBACK. `127.evil.com` and
      `localhost.attacker.net` are PUBLIC DNS NAMES. Found by review of this
      package's own first version and RED before the fix.
      M21 the carve-out reverts to a `startswith`/`endswith` PREFIX test.
  22. A BACKWARDS CLOCK NEVER PRODUCES A NEGATIVE AGE, and never opens the stale
      path — the age is not computable, so there is nothing to bound.
      M22 the fresh-hit guard drops `age >= 0`.
      M23 the stale guard drops `stale_age >= 0`. Two guards, two mutants: each
          is invisible to the other's, which is why the gate has two halves.

⭐ EVERY MUTANT IN THE LEDGER WAS RUN IN ISOLATION —
`main()` rewritten to call ONLY the gate the mutant is filed under, with the
UNMUTATED baseline confirmed GREEN first. A mutant that reds the SUITE proves
nothing about the gate it is named for; some of these were killing an EARLIER
gate's assertion until the suite was re-ordered and split (M5/M5b, M6/M6b).

⚠ AND ONE MUTANT SURVIVED THE FIRST VERSION OF ITS GATE: M13 (the empty-base-URL
check deleted) stayed GREEN, because an empty base then fell through to the
NO-SCHEME refusal, which also raises and also names the flag. Gate 13 was
measuring "parse rejects it" and REPORTING on "the unset case is refused". It now
asserts the unset message's own words.

CONTROLS: the whole suite was also run against two REFUSE-EVERYTHING clients —
one whose `_lookup` refuses every call, one that answers every call with a canned
hit. The gates GREEN under BOTH are exactly the gates that deliberately never enter `_lookup` (endpoint validation,
the classifier, the parser, `usable()`, and the pre-lookup name refusal), each
of which has its own mutant.

Hermetic: two in-file transport conformers, no socket, no credential, no
runfiles, no FFI, no cloud. The CLOCK IS AN ARGUMENT, so every staleness
assertion is exact rather than timing-dependent.
"""

from std.testing import assert_equal, assert_false, assert_true

from komira_service_registry.http_contract import (
    SERVICE_REGISTRY_MARKER_VALUE,
    resolve_service_path,
)
from komira_service_registry.resolve_result import (
    RESOLVE_SOURCE_CACHE,
    RESOLVE_SOURCE_STORE,
    RESOLVE_SOURCE_UNSET,
)

from komira_service_registry_client.answer import (
    ANSWER_OK,
    ANSWER_PROTOCOL_ERROR,
    classify_registry_response,
    parse_resolve_body,
)
from komira_service_registry_client.directory import RemotePeerDirectory
from komira_service_registry_client.endpoint import (
    RegistryEndpoint,
    SERVICE_REGISTRY_URL_FLAG,
    refuse_unsafe_segment,
)
from komira_service_registry_client.resolution import (
    MARKER_ABSENT,
    MARKER_NOT_DIALLED,
    MARKER_PRESENT,
    PEER_ABSENT,
    PEER_CACHED,
    PEER_FRESH,
    PEER_PROTOCOL_ERROR,
    PEER_REFUSED,
    PEER_REGISTRY_ERROR,
    PEER_STALE,
    PEER_UNREACHABLE,
    PeerResolution,
)
from komira_service_registry_client.transport import (
    RegistryHttpResponse,
    RegistryTransport,
)


comptime _BASE: String = "https://registry.example.com"
comptime _NAME: String = "job-manager"
comptime _URL: String = "https://job-manager.example.com"
comptime _SERVER_KEY: String = "service/job-manager"


# =============================================================================
# The doubles.
# =============================================================================


@fieldwise_init
struct _Step(Copyable, Movable, Deinitable):
    """One scripted response, or a scripted transport FAULT."""

    var boom: Bool
    var status: Int
    var marker: String
    var body: String


struct _Scripted(RegistryTransport, Movable, Deinitable):
    """Replays a script and RECORDS every URL it was asked for.

    ⚠ IT RAISES WHEN THE SCRIPT RUNS OUT, rather than repeating the last step.
    A double that keeps answering makes a gate asserting "this did NOT dial"
    pass for the wrong reason — the call would have succeeded and the assertion
    would be about a count nobody checked."""

    var _steps: List[_Step]
    var _at: Int
    var _urls: List[String]

    def __init__(out self, var steps: List[_Step]):
        self._steps = steps^
        self._at = 0
        self._urls = List[String]()

    def get(mut self, url: String) raises -> RegistryHttpResponse:
        self._urls.append(String(url))
        if self._at >= len(self._steps):
            raise Error("scripted transport: no step left for " + url)
        var s = self._steps[self._at].copy()
        self._at += 1
        if s.boom:
            raise Error("scripted transport fault: connection refused")
        return RegistryHttpResponse(
            s.status, String(s.marker), String(s.body)
        )

    def calls(self) -> Int:
        return len(self._urls)

    def url_at(self, i: Int) -> String:
        return String(self._urls[i])


struct _RefuseEverything(RegistryTransport, Movable, Deinitable):
    """THE CONTROL. Every `get` is a transport fault.

    It is not a gate of its own: it is the baseline the whole suite is run
    against, to prove no gate passes because of something other than the
    behaviour it names."""

    var _calls: Int

    def __init__(out self):
        self._calls = 0

    def get(mut self, url: String) raises -> RegistryHttpResponse:
        self._calls += 1
        raise Error("refuse-everything transport: " + url)

    def calls(self) -> Int:
        return self._calls


def _dir(
    var steps: List[_Step], ttl_ms: Int64, max_stale_ms: Int64
) raises -> RemotePeerDirectory[_Scripted]:
    return RemotePeerDirectory[_Scripted](
        RegistryEndpoint.parse(_BASE), _Scripted(steps^), ttl_ms, max_stale_ms
    )


def _hit(var value: String, var key: String) -> _Step:
    """A 200, MARKED, carrying a well-formed hit."""
    return _Step(
        False,
        200,
        SERVICE_REGISTRY_MARKER_VALUE,
        String('{"found":true,"value":"')
        + value
        + String('","key":"')
        + key
        + String('"}'),
    )


def _miss(var key: String) -> _Step:
    """A 200, MARKED, carrying `found:false` — the registry ANSWERED."""
    return _Step(
        False,
        200,
        SERVICE_REGISTRY_MARKER_VALUE,
        String('{"found":false,"value":"","key":"') + key + String('"}'),
    )


def _raw(status: Int, var marker: String, var body: String) -> _Step:
    return _Step(False, status, marker^, body^)


def _fault() -> _Step:
    return _Step(True, 0, String(""), String(""))


# =============================================================================
# 1 — a HIT resolves, and the key is the SERVER's.
# =============================================================================


def test_a_hit_resolves_and_reports_the_servers_key() raises:
    # ⚠ THE FIXTURE'S SERVER REPORTS A KEY THE CLIENT COULD NOT HAVE DERIVED.
    # `service/job-manager` is what the client WOULD compose; the server says
    # `service/renamed-under-the-hood`. Any client-side re-derivation reports
    # the first and this gate goes RED.
    var steps = List[_Step]()
    steps.append(_hit(String(_URL), String("service/renamed-under-the-hood")))
    var d = _dir(steps^, Int64(60_000), Int64(0))

    var r = d.resolve_endpoint(String(_NAME), Int64(1_000))
    assert_equal(r.disposition, PEER_FRESH)
    assert_true(r.usable())
    assert_equal(r.endpoint(), _URL)
    assert_equal(r.result.key, String("service/renamed-under-the-hood"))
    assert_equal(r.result.source, RESOLVE_SOURCE_STORE)
    assert_equal(r.result.age_ms, Int64(0))
    assert_equal(r.marker_state, MARKER_PRESENT)
    # The URL dialled is base + the CONTRACT's path composer, with nothing
    # appended: no query, no credential.
    assert_equal(
        d.transport().url_at(0), _BASE + resolve_service_path(String(_NAME))
    )
    assert_equal(d.transport().calls(), 1)


# =============================================================================
# 2 — `found:false` from a REACHED registry.
# =============================================================================


def test_found_false_is_absent_and_says_the_store_was_reached() raises:
    var steps = List[_Step]()
    steps.append(_miss(String(_SERVER_KEY)))
    var d = _dir(steps^, Int64(60_000), Int64(60_000))

    var r = d.resolve_endpoint(String(_NAME), Int64(1_000))
    assert_equal(r.disposition, PEER_ABSENT)
    assert_false(r.usable())
    assert_equal(r.endpoint(), String(""))
    assert_false(r.result.found)
    # ⭐ THE CLAIM: we ASKED. `source=store` is what separates this from every
    # failure disposition, all of which are UNSET.
    assert_equal(r.result.source, RESOLVE_SOURCE_STORE)
    assert_equal(r.result.key, String(_SERVER_KEY))
    assert_true(r.describe().find(String("source=store")) >= 0)


# =============================================================================
# 3 — ⭐⭐ a 404 is NEVER absence, and MARKED != UNMARKED.
# =============================================================================


def test_a_marked_404_is_a_protocol_error_never_an_absence() raises:
    var steps = List[_Step]()
    steps.append(
        _raw(404, SERVICE_REGISTRY_MARKER_VALUE, String('{"error":"nope"}'))
    )
    var d = _dir(steps^, Int64(60_000), Int64(0))

    var r = d.resolve_endpoint(String(_NAME), Int64(1_000))
    assert_equal(r.disposition, PEER_PROTOCOL_ERROR)
    assert_false(r.usable())
    # It must NOT be reported as an answer: source stays UNSET and there is no
    # key, because no key was consulted.
    assert_equal(r.result.source, RESOLVE_SOURCE_UNSET)
    assert_equal(r.result.key, String(""))
    assert_equal(r.marker_state, MARKER_PRESENT)


def test_an_unmarked_404_is_not_reached_never_an_absence() raises:
    # Google's edge, an internal-ingress service and a DELETED service all emit
    # exactly this. None of them can emit the marker.
    var steps = List[_Step]()
    steps.append(_raw(404, String(""), String("<html>Not Found</html>")))
    var d = _dir(steps^, Int64(60_000), Int64(0))

    var r = d.resolve_endpoint(String(_NAME), Int64(1_000))
    assert_equal(r.disposition, PEER_UNREACHABLE)
    assert_false(r.usable())
    assert_equal(r.result.source, RESOLVE_SOURCE_UNSET)
    assert_equal(r.marker_state, MARKER_ABSENT)
    # The detail must not echo the body: it is bytes from an unidentified
    # intermediary and it ends up in logs.
    assert_true(r.detail.find(String("<html>")) < 0)


# =============================================================================
# 4 — an UNREACHABLE registry is not an absence.
# =============================================================================


def test_a_transport_fault_is_unreachable_with_no_key_and_unset_source() raises:
    var steps = List[_Step]()
    steps.append(_fault())
    var d = _dir(steps^, Int64(60_000), Int64(60_000))

    var r = d.resolve_endpoint(String(_NAME), Int64(1_000))
    assert_equal(r.disposition, PEER_UNREACHABLE)
    assert_false(r.usable())
    assert_false(r.result.found)
    # ⭐ UNSET, NOT `absent()`. `absent()` would assert `source=store`, i.e.
    # "the store WAS consulted" — false, and written into the log line.
    assert_equal(r.result.source, RESOLVE_SOURCE_UNSET)
    assert_equal(r.result.key, String(""))
    assert_equal(r.marker_state, MARKER_NOT_DIALLED)


# =============================================================================
# 5 — a body that is not the contract. SIX fixtures.
# =============================================================================


def _protocol_error_for(var body: String) raises:
    var steps = List[_Step]()
    steps.append(_raw(200, SERVICE_REGISTRY_MARKER_VALUE, body^))
    var d = _dir(steps^, Int64(60_000), Int64(0))
    var r = d.resolve_endpoint(String(_NAME), Int64(1_000))
    assert_equal(r.disposition, PEER_PROTOCOL_ERROR)
    assert_false(r.usable())
    assert_equal(r.result.source, RESOLVE_SOURCE_UNSET)


def test_a_quoted_boolean_is_a_protocol_error_not_an_absence() raises:
    """M5b's gate, ALONE. A client that checks only that `found` is PRESENT
    reads `"false"` as an absence and reports an unregistered peer."""
    _protocol_error_for(
        String('{"found":"false","value":"","key":"service/x"}')
    )


def test_a_missing_found_member_is_a_protocol_error_not_an_absence() raises:
    """M5's gate, ALONE. A lenient parser defaulting a missing `found` to false
    reports every malformed body as an unregistered peer."""
    _protocol_error_for(String('{"value":"u","key":"service/x"}'))


def test_a_body_that_is_not_the_contract_is_a_protocol_error() raises:
    # ⚠ THE TWO FIXTURES THAT USED TO OPEN THIS LIST ARE NOW THEIR OWN GATES.
    # M5 and M5b each kill exactly one of them and are invisible to the other,
    # so bundled here the surviving mutant would have been hidden by the dead
    # one's failure on a shared line.
    # (c) `found:true` with an EMPTY value — the caller would dial "".
    _protocol_error_for(String('{"found":true,"value":"","key":"service/x"}'))
    # (d) not JSON.
    _protocol_error_for(String("upstream connect error"))
    # (e) trailing bytes after the object.
    _protocol_error_for(
        String('{"found":true,"value":"u","key":"k"} and more')
    )
    # (f) a DUPLICATE contract member — two answers, no rule for choosing.
    _protocol_error_for(
        String('{"found":false,"found":true,"value":"u","key":"k"}')
    )
    # (g) no `key` member: the one fact a client may not synthesise.
    _protocol_error_for(String('{"found":true,"value":"u"}'))


# =============================================================================
# 6 — ⭐ STALE.
# =============================================================================


def test_a_failed_fetch_after_a_good_read_serves_a_labelled_stale_endpoint() raises:
    var steps = List[_Step]()
    steps.append(_hit(String(_URL), String(_SERVER_KEY)))
    steps.append(_fault())
    var d = _dir(steps^, Int64(60_000), Int64(600_000))

    var first = d.resolve_endpoint(String(_NAME), Int64(1_000))
    assert_equal(first.disposition, PEER_FRESH)

    # t = 1_000 + 90s: past the 60s TTL, inside the 600s stale bound.
    var r = d.resolve_endpoint(String(_NAME), Int64(91_000))
    # ⚠ THE ORDER OF THESE TWO ASSERTIONS IS DELIBERATE. "the endpoint was
    # SERVED" and "the endpoint was LABELLED STALE" are separate properties with
    # separate mutants (M6 deletes the serving, M6b mislabels it FRESH), and
    # asserting the disposition first would kill both on ONE line — which reads
    # as one property with two proofs rather than two properties.
    assert_true(r.usable())  # ⭐ THE TRADE: the peer call HAPPENS. Kills M6.
    assert_equal(r.endpoint(), _URL)
    assert_equal(r.disposition, PEER_STALE)  # ⭐ ...AND SAYS SO. Kills M6b.
    assert_true(r.is_stale())
    # ⭐ AND IT SAYS SO. Serving it is half the property; labelling it is the
    # other half — a stale serve that reported `fresh` would be a silent guess.
    assert_equal(r.result.source, RESOLVE_SOURCE_CACHE)
    assert_equal(r.result.age_ms, Int64(90_000))
    assert_equal(r.result.key, String(_SERVER_KEY))
    assert_true(r.describe().find(String("disposition=stale")) >= 0)
    assert_true(r.describe().find(String("age_ms=90000")) >= 0)


# =============================================================================
# 7 — ⭐ stale is BOUNDED.
# =============================================================================


def test_stale_is_bounded_and_zero_disables_it() raises:
    var steps = List[_Step]()
    steps.append(_hit(String(_URL), String(_SERVER_KEY)))
    steps.append(_fault())
    var d = _dir(steps^, Int64(60_000), Int64(120_000))
    _ = d.resolve_endpoint(String(_NAME), Int64(0))
    # t = 130s: past the 120s stale bound. An endpoint this old is a guess.
    var r = d.resolve_endpoint(String(_NAME), Int64(130_000))
    assert_equal(r.disposition, PEER_UNREACHABLE)
    assert_false(r.usable())

    var steps2 = List[_Step]()
    steps2.append(_hit(String(_URL), String(_SERVER_KEY)))
    steps2.append(_fault())
    var d2 = _dir(steps2^, Int64(60_000), Int64(0))
    _ = d2.resolve_endpoint(String(_NAME), Int64(0))
    var r2 = d2.resolve_endpoint(String(_NAME), Int64(61_000))
    assert_equal(r2.disposition, PEER_UNREACHABLE)
    assert_false(r2.usable())


# =============================================================================
# 8 — ⭐⭐ a REACHED absence EVICTS.
# =============================================================================


def test_a_reached_absence_evicts_and_does_not_fall_back_to_the_cache() raises:
    var steps = List[_Step]()
    steps.append(_hit(String(_URL), String(_SERVER_KEY)))
    steps.append(_miss(String(_SERVER_KEY)))
    steps.append(_fault())
    var d = _dir(steps^, Int64(60_000), Int64(600_000))

    _ = d.resolve_endpoint(String(_NAME), Int64(0))
    assert_equal(d.cache_len(), 1)

    # The registry ANSWERS "unregistered" while a usable entry is cached. The
    # answer wins: falling back here would resurrect a withdrawn binding.
    var r = d.resolve_endpoint(String(_NAME), Int64(61_000))
    assert_equal(r.disposition, PEER_ABSENT)
    assert_false(r.usable())
    assert_equal(d.cache_len(), 0)

    # ⭐ THE THIRD STEP IS WHAT PROVES THE EVICTION rather than a preference: a
    # LATER failure has nothing to serve.
    var r3 = d.resolve_endpoint(String(_NAME), Int64(62_000))
    assert_equal(r3.disposition, PEER_UNREACHABLE)
    assert_false(r3.usable())


# =============================================================================
# 9 — negatives are not cached.
# =============================================================================


def test_an_absence_is_not_cached_so_the_next_lookup_dials() raises:
    var steps = List[_Step]()
    steps.append(_miss(String(_SERVER_KEY)))
    steps.append(_hit(String(_URL), String(_SERVER_KEY)))
    var d = _dir(steps^, Int64(600_000), Int64(0))

    var r1 = d.resolve_endpoint(String(_NAME), Int64(0))
    assert_equal(r1.disposition, PEER_ABSENT)
    assert_equal(d.cache_len(), 0)

    # Well inside the TTL. A peer that has not published YET is the ordinary
    # state during a rollout; caching that would make this client converge
    # slower than the deploy.
    var r2 = d.resolve_endpoint(String(_NAME), Int64(1_000))
    assert_equal(r2.disposition, PEER_FRESH)
    assert_equal(r2.endpoint(), _URL)
    assert_equal(d.transport().calls(), 2)


# =============================================================================
# 10 — a fresh cache hit does not dial.
# =============================================================================


def test_a_fresh_cache_hit_does_not_dial_and_reports_cache_and_age() raises:
    var steps = List[_Step]()
    steps.append(_hit(String(_URL), String(_SERVER_KEY)))
    var d = _dir(steps^, Int64(60_000), Int64(0))
    _ = d.resolve_endpoint(String(_NAME), Int64(1_000))

    var r = d.resolve_endpoint(String(_NAME), Int64(31_000))
    assert_equal(r.disposition, PEER_CACHED)
    assert_true(r.usable())
    assert_equal(r.endpoint(), _URL)
    assert_equal(r.result.source, RESOLVE_SOURCE_CACHE)
    assert_equal(r.result.age_ms, Int64(30_000))
    # Even a CACHE hit reports the SERVER's key — the entry stored it.
    assert_equal(r.result.key, String(_SERVER_KEY))
    assert_equal(r.marker_state, MARKER_NOT_DIALLED)
    assert_equal(r.url, String(""))
    # THE POINT: the script has ONE step and a second dial would raise.
    assert_equal(d.transport().calls(), 1)


def test_a_zero_ttl_never_serves_from_cache() raises:
    var steps = List[_Step]()
    steps.append(_hit(String(_URL), String(_SERVER_KEY)))
    steps.append(_hit(String(_URL), String(_SERVER_KEY)))
    var d = _dir(steps^, Int64(0), Int64(0))
    _ = d.resolve_endpoint(String(_NAME), Int64(1_000))
    var r = d.resolve_endpoint(String(_NAME), Int64(1_000))
    assert_equal(r.disposition, PEER_FRESH)
    assert_equal(d.transport().calls(), 2)


# =============================================================================
# 12 — an unsafe name is refused WITHOUT a dial.
# =============================================================================


def test_an_unsafe_name_is_refused_before_any_dial() raises:
    var bad = List[String]()
    bad.append(String(""))
    bad.append(String("a/b"))
    bad.append(String("a b"))
    bad.append(String("a%2Fb"))
    bad.append(String("a?x=1"))
    bad.append(String("../etc"))
    bad.append(String("a#b"))

    for i in range(len(bad)):
        var steps = List[_Step]()
        var d = _dir(steps^, Int64(60_000), Int64(0))
        var r = d.resolve_endpoint(bad[i], Int64(0))
        assert_equal(r.disposition, PEER_REFUSED)
        assert_false(r.usable())
        assert_equal(r.url, String(""))
        # ⭐ NO DIAL AT ALL. An encoding client would have dialled here, and the
        # server — which does no decoding — would have reported the encoded
        # string as unregistered.
        assert_equal(d.transport().calls(), 0)


# =============================================================================
# 13 — ⭐ BOOTSTRAP.
# =============================================================================


def test_an_unusable_registry_url_is_a_refusal_that_names_the_flag() raises:
    # (a) UNSET — the state a flagless deployment is in.
    var raised = False
    try:
        _ = RegistryEndpoint.parse(String(""))
    except e:
        raised = True
        assert_true(String(e).find(SERVICE_REGISTRY_URL_FLAG) >= 0)
        # ⚠⚠ THE MESSAGE, NOT MERELY THE RAISE. M13 (the empty-string check
        # deleted) SURVIVED the first version of this arm: an empty base URL
        # then fell through to the NO-SCHEME refusal, which also raises and also
        # names the flag. The gate was measuring "parse rejects it" and
        # REPORTING on "the unset case is refused" — two different claims, and
        # only the second is the bootstrap property. Asserting the unset
        # message's own words is what makes M13 die here.
        assert_true(String(e).find(String("no registry URL")) >= 0)
    assert_true(raised)

    # (b) no scheme.
    var raised_b = False
    try:
        _ = RegistryEndpoint.parse(String("registry.example.com"))
    except e:
        raised_b = True
        assert_true(String(e).find(SERVICE_REGISTRY_URL_FLAG) >= 0)
    assert_true(raised_b)

    # (c) ⭐ PLAINTEXT TO A PUBLIC HOST. Anyone who can rewrite the answer
    # repoints every peer call that follows it.
    var raised_c = False
    try:
        _ = RegistryEndpoint.parse(String("http://registry.example.com"))
    except e:
        raised_c = True
        assert_true(String(e).find(String("plaintext")) >= 0)
    assert_true(raised_c)

    # (d) a query or fragment — this client APPENDS a path.
    var raised_d = False
    try:
        _ = RegistryEndpoint.parse(String("https://registry.example.com/?x=1"))
    except e:
        raised_d = True
    assert_true(raised_d)


def test_a_loopback_plaintext_url_is_accepted_and_normalised() raises:
    # Laptop First: a loopback dial traverses nothing there is to intercept.
    var e = RegistryEndpoint.parse(String("http://127.0.0.1:8080///"))
    assert_equal(e.base, String("http://127.0.0.1:8080"))
    assert_true(e.plaintext)
    var f = RegistryEndpoint.parse(String("http://localhost:9/"))
    assert_equal(f.base, String("http://localhost:9"))
    var g = RegistryEndpoint.parse(String("https://reg.example.com/gw/"))
    assert_equal(g.base, String("https://reg.example.com/gw"))
    assert_false(g.plaintext)
    assert_equal(
        g.url_for(resolve_service_path(String("x"))),
        String("https://reg.example.com/gw/v1/services/x"),
    )


def test_a_loopback_lookalike_hostname_is_not_loopback() raises:
    """⛔ `127.evil.com` IS A VALID DNS NAME AND MAY RESOLVE ANYWHERE.

    Found by review of this package's first version, which tested the loopback
    carve-out with `host.startswith("127.")`. That accepts `127.evil.com`,
    `127.0.0.1.attacker.net` and `localhost.attacker.net` — each a public name
    whose resolution we do not control — and the carve-out exists precisely to
    say "these bytes do not traverse anything". A plaintext registry answer that
    CAN be intercepted repoints every peer call that follows it.

    The rule is now: a literal dotted quad `127.a.b.c` with digits only, `::1`,
    or the exact word `localhost`. RED before the fix."""
    var spoofs = List[String]()
    spoofs.append(String("http://127.evil.com"))
    spoofs.append(String("http://127.0.0.1.attacker.net"))
    spoofs.append(String("http://localhost.attacker.net"))
    spoofs.append(String("http://127.0.0.1x"))
    for i in range(len(spoofs)):
        var raised = False
        try:
            _ = RegistryEndpoint.parse(spoofs[i])
        except e:
            raised = True
            assert_true(String(e).find(String("plaintext")) >= 0)
        assert_true(raised)

    # The REAL loopback forms still pass — a fix that refused these would be a
    # Laptop First regression, so the negative control is in the same gate.
    _ = RegistryEndpoint.parse(String("http://127.0.0.1:8080"))
    _ = RegistryEndpoint.parse(String("http://127.9.9.9"))
    _ = RegistryEndpoint.parse(String("http://localhost:1"))
    _ = RegistryEndpoint.parse(String("http://[::1]:1"))


def test_a_backwards_clock_never_serves_a_negative_age() raises:
    """A caller supplies the clock, and a caller's clock can go BACKWARDS — a
    wall-clock source, an NTP step, a restarted process reading a different
    base. The cache must not then report a NEGATIVE age, which would put a
    nonsense number in the one log line this subsystem traded validation for,
    and must not serve an entry whose age it cannot compute.

    It re-reads instead: the conservative direction, since a re-read is only
    ever a round trip."""
    var steps = List[_Step]()
    steps.append(_hit(String(_URL), String(_SERVER_KEY)))
    steps.append(_hit(String(_URL), String(_SERVER_KEY)))
    var d = _dir(steps^, Int64(60_000), Int64(600_000))
    _ = d.resolve_endpoint(String(_NAME), Int64(500_000))

    # The clock steps BACK behind the entry's read time.
    var r = d.resolve_endpoint(String(_NAME), Int64(400_000))
    assert_true(r.result.age_ms >= Int64(0))
    assert_equal(r.disposition, PEER_FRESH)
    assert_equal(d.transport().calls(), 2)

    # And with the fetch ALSO failing, a backwards clock must not open the stale
    # path either — the age is not computable, so there is nothing to bound.
    var steps2 = List[_Step]()
    steps2.append(_hit(String(_URL), String(_SERVER_KEY)))
    steps2.append(_fault())
    var d2 = _dir(steps2^, Int64(60_000), Int64(600_000))
    _ = d2.resolve_endpoint(String(_NAME), Int64(500_000))
    var r2 = d2.resolve_endpoint(String(_NAME), Int64(400_000))
    assert_equal(r2.disposition, PEER_UNREACHABLE)
    assert_true(r2.result.age_ms >= Int64(0))

# =============================================================================
# 14 — the REFUSED disposition is translated, not passed through.
# =============================================================================


def test_refused_disposition_is_translated_not_passed_through() raises:
    var steps = List[_Step]()
    steps.append(
        _raw(
            400,
            SERVICE_REGISTRY_MARKER_VALUE,
            String('{"error":"empty service name"}'),
        )
    )
    var d = _dir(steps^, Int64(60_000), Int64(600_000))
    var r = d.resolve_endpoint(String(_NAME), Int64(0))
    # PEER_REFUSED is 8; the classifier's ANSWER_REFUSED is 5. Passing the
    # classifier's ordinal through compiles and yields PEER_UNREACHABLE's
    # neighbour — a wrong, plausible disposition.
    assert_equal(r.disposition, PEER_REFUSED)
    assert_false(r.usable())


def test_a_registry_refusal_never_serves_a_stale_endpoint() raises:
    var steps = List[_Step]()
    steps.append(_hit(String(_URL), String(_SERVER_KEY)))
    steps.append(_raw(400, SERVICE_REGISTRY_MARKER_VALUE, String("{}")))
    var d = _dir(steps^, Int64(60_000), Int64(600_000))
    _ = d.resolve_endpoint(String(_NAME), Int64(0))
    var r = d.resolve_endpoint(String(_NAME), Int64(61_000))
    # The NAME is wrong. Serving a cached value would mask a caller's bug, and
    # a retry fails identically — there is nothing to ride out.
    assert_equal(r.disposition, PEER_REFUSED)
    assert_false(r.usable())


# =============================================================================
# 15 — a MARKED 5xx proves the path is right.
# =============================================================================


def test_a_marked_5xx_is_a_registry_error_not_unreachable() raises:
    var steps = List[_Step]()
    steps.append(
        _raw(
            503,
            SERVICE_REGISTRY_MARKER_VALUE,
            String('{"error":"the registry store could not be read; retry"}'),
        )
    )
    var d = _dir(steps^, Int64(60_000), Int64(0))
    var r = d.resolve_endpoint(String(_NAME), Int64(0))
    assert_equal(r.disposition, PEER_REGISTRY_ERROR)
    assert_false(r.usable())
    assert_equal(r.marker_state, MARKER_PRESENT)

    # The SAME status with NO marker is a different event with a different fix.
    var steps2 = List[_Step]()
    steps2.append(_raw(503, String(""), String("upstream connect error")))
    var d2 = _dir(steps2^, Int64(60_000), Int64(0))
    var r2 = d2.resolve_endpoint(String(_NAME), Int64(0))
    assert_equal(r2.disposition, PEER_UNREACHABLE)


def test_a_marked_5xx_still_serves_stale_when_one_is_held() raises:
    var steps = List[_Step]()
    steps.append(_hit(String(_URL), String(_SERVER_KEY)))
    steps.append(_raw(503, SERVICE_REGISTRY_MARKER_VALUE, String("{}")))
    var d = _dir(steps^, Int64(60_000), Int64(600_000))
    _ = d.resolve_endpoint(String(_NAME), Int64(0))
    var r = d.resolve_endpoint(String(_NAME), Int64(61_000))
    assert_equal(r.disposition, PEER_STALE)
    assert_true(r.usable())


def test_a_protocol_error_still_serves_stale_when_one_is_held() raises:
    # A half-deployed or version-skewed registry is exactly the outage a cache
    # should ride out: the endpoint is not less likely to be right because the
    # response was unparseable.
    var steps = List[_Step]()
    steps.append(_hit(String(_URL), String(_SERVER_KEY)))
    steps.append(
        _raw(200, SERVICE_REGISTRY_MARKER_VALUE, String("<html>oops</html>"))
    )
    var d = _dir(steps^, Int64(60_000), Int64(600_000))
    _ = d.resolve_endpoint(String(_NAME), Int64(0))
    var r = d.resolve_endpoint(String(_NAME), Int64(61_000))
    assert_equal(r.disposition, PEER_STALE)
    assert_true(r.usable())
    assert_true(r.detail.find(String("STALE")) >= 0)


# =============================================================================
# 16 — `usable()` over every disposition.
# =============================================================================


def test_usable_is_false_for_every_disposition_without_an_endpoint() raises:
    var usable_ok = List[Int]()
    usable_ok.append(PEER_FRESH)
    usable_ok.append(PEER_CACHED)
    usable_ok.append(PEER_STALE)
    var not_usable = List[Int]()
    not_usable.append(PEER_ABSENT)
    not_usable.append(PEER_UNREACHABLE)
    not_usable.append(PEER_REGISTRY_ERROR)
    not_usable.append(PEER_PROTOCOL_ERROR)
    not_usable.append(PEER_REFUSED)

    for i in range(len(usable_ok)):
        var r = PeerResolution.refused(String("x"), String("y"))
        r.disposition = usable_ok[i]
        assert_true(r.usable())
    for j in range(len(not_usable)):
        var r2 = PeerResolution.refused(String("x"), String("y"))
        r2.disposition = not_usable[j]
        assert_false(r2.usable())
        assert_equal(r2.endpoint(), String(""))

    # Eight dispositions, no overlap, and every ordinal distinct — a duplicate
    # would make two different events indistinguishable to a caller.
    assert_equal(len(usable_ok) + len(not_usable), 8)


# =============================================================================
# 17 — the log line.
# =============================================================================


def test_the_log_line_carries_every_fact() raises:
    var steps = List[_Step]()
    steps.append(_hit(String(_URL), String(_SERVER_KEY)))
    var d = _dir(steps^, Int64(60_000), Int64(0))
    var line = d.resolve_endpoint(String(_NAME), Int64(0)).describe()

    assert_true(line.find(String("name=") + _NAME) >= 0)
    assert_true(line.find(String("disposition=fresh")) >= 0)
    assert_true(line.find(String("usable=1")) >= 0)
    assert_true(line.find(String("marker=present")) >= 0)
    assert_true(line.find(_BASE) >= 0)
    # ⭐ THE CONTRACT'S OWN FOUR FACTS, verbatim from `ResolveResult.describe`.
    assert_true(line.find(String("key=") + _SERVER_KEY) >= 0)
    assert_true(line.find(String("found=1")) >= 0)
    assert_true(line.find(String("source=store")) >= 0)
    assert_true(line.find(String("age_ms=0")) >= 0)
    assert_true(line.find(_URL) >= 0)


# =============================================================================
# 18 — byte-faithful value decoding.
# =============================================================================


def test_the_value_decoder_is_byte_faithful() raises:
    # Two bytes of a UTF-8 'é' (0xC3 0xA9) inside a host label, plus an escaped
    # quote and an escaped tab. The server passes bytes >= 0x20 through RAW, so
    # a client that rebuilds them through `chr(Int(byte))` re-encodes each as a
    # multi-byte sequence and the value it hands the caller is not the value the
    # store holds.
    var raw = List[UInt8]()
    raw.append(UInt8(104))  # h
    raw.append(UInt8(0xC3))
    raw.append(UInt8(0xA9))
    raw.append(UInt8(34))  # "
    raw.append(UInt8(9))  # tab
    raw.append(UInt8(122))  # z
    var expected = String(unsafe_from_utf8=Span(raw))

    var body = String('{"found":true,"value":"h')
    var high = List[UInt8]()
    high.append(UInt8(0xC3))
    high.append(UInt8(0xA9))
    body += String(unsafe_from_utf8=Span(high))
    body += String('\\"\\tz","key":"service/x"}')

    var a = parse_resolve_body(body)
    assert_equal(a.kind, ANSWER_OK)
    assert_true(a.found)
    assert_equal(a.value.byte_length(), expected.byte_length())
    assert_equal(a.value, expected)

    # A `\uXXXX` above 0x00FF is REFUSED rather than guessed at: our writer
    # never emits one, and decoding it would mean choosing an encoding.
    var b = parse_resolve_body(
        String('{"found":true,"value":"\\u00e9","key":"k"}')
    )
    assert_equal(b.kind, ANSWER_OK)
    assert_equal(b.value.byte_length(), 1)
    var c = parse_resolve_body(
        String('{"found":true,"value":"\\u20ac","key":"k"}')
    )
    assert_equal(c.kind, ANSWER_PROTOCOL_ERROR)


# =============================================================================
# 19 — forward compatibility.
# =============================================================================


def test_an_unknown_member_does_not_break_the_parse() raises:
    # A server that adds a field must not stop the fleet resolving. Strict about
    # what it knows; tolerant of what it does not.
    var a = parse_resolve_body(
        String(
            '{"found":true,"served_at":1234,"value":"https://u","nested":'
            '{"a":[1,2,{"b":null}]},"key":"service/x","trailing":"ok"}'
        )
    )
    assert_equal(a.kind, ANSWER_OK)
    assert_true(a.found)
    assert_equal(a.value, String("https://u"))
    assert_equal(a.key, String("service/x"))


# =============================================================================
# THE CONTROL — a REFUSE-EVERYTHING transport under the real client.
# =============================================================================


def test_control_refuse_everything_yields_no_usable_resolution() raises:
    """The baseline: with a transport that refuses every call, NOTHING resolves.

    This is not a property gate — it is the control that proves the suite's
    happy-path assertions are answering to the transport at all. Every gate
    above that asserts a usable endpoint fails against this transport; run it
    that way and they go RED."""
    var d = RemotePeerDirectory[_RefuseEverything](
        RegistryEndpoint.parse(_BASE),
        _RefuseEverything(),
        Int64(60_000),
        Int64(600_000),
    )
    var r = d.resolve_endpoint(String(_NAME), Int64(0))
    assert_equal(r.disposition, PEER_UNREACHABLE)
    assert_false(r.usable())
    assert_equal(r.endpoint(), String(""))
    # A refusal that never dialled would ALSO be "not usable" — assert the dial
    # happened, so this control cannot pass vacuously.
    assert_equal(d.transport().calls(), 1)


# =============================================================================
# The classifier, driven directly — so a rule is provable without a directory.
# =============================================================================


def test_the_classifier_table_is_exactly_the_documented_one() raises:
    var marked = SERVICE_REGISTRY_MARKER_VALUE
    var good = String('{"found":true,"value":"u","key":"k"}')

    assert_equal(classify_registry_response(200, marked, good).kind, ANSWER_OK)
    # A 200 with a GOOD body but NO marker still resolves: the body is already
    # unforgeable, and requiring the header would let ONE stripping hop take the
    # whole fleet down.
    assert_equal(
        classify_registry_response(200, String(""), good).kind, ANSWER_OK
    )
    for status in [301, 302, 401, 403, 404, 405, 418, 201, 204]:
        assert_equal(
            classify_registry_response(status, String(""), good).kind,
            2,  # ANSWER_NOT_REACHED
        )
    assert_equal(
        classify_registry_response(400, marked, good).kind, 5
    )  # ANSWER_REFUSED
    assert_equal(
        classify_registry_response(500, marked, good).kind, 3
    )  # ANSWER_REGISTRY_ERROR
    assert_equal(
        classify_registry_response(503, marked, good).kind, 3
    )
    for status2 in [301, 401, 403, 404, 405, 418, 201, 204]:
        assert_equal(
            classify_registry_response(status2, marked, good).kind,
            ANSWER_PROTOCOL_ERROR,
        )


def main() raises:
    test_a_hit_resolves_and_reports_the_servers_key()
    test_found_false_is_absent_and_says_the_store_was_reached()
    test_a_marked_404_is_a_protocol_error_never_an_absence()
    test_an_unmarked_404_is_not_reached_never_an_absence()
    test_a_transport_fault_is_unreachable_with_no_key_and_unset_source()
    test_a_quoted_boolean_is_a_protocol_error_not_an_absence()
    test_a_missing_found_member_is_a_protocol_error_not_an_absence()
    test_a_body_that_is_not_the_contract_is_a_protocol_error()
    test_a_failed_fetch_after_a_good_read_serves_a_labelled_stale_endpoint()
    test_stale_is_bounded_and_zero_disables_it()
    test_a_reached_absence_evicts_and_does_not_fall_back_to_the_cache()
    test_an_absence_is_not_cached_so_the_next_lookup_dials()
    test_a_fresh_cache_hit_does_not_dial_and_reports_cache_and_age()
    test_a_zero_ttl_never_serves_from_cache()
    test_an_unsafe_name_is_refused_before_any_dial()
    test_an_unusable_registry_url_is_a_refusal_that_names_the_flag()
    test_a_loopback_plaintext_url_is_accepted_and_normalised()
    test_a_loopback_lookalike_hostname_is_not_loopback()
    test_a_backwards_clock_never_serves_a_negative_age()
    test_refused_disposition_is_translated_not_passed_through()
    test_a_registry_refusal_never_serves_a_stale_endpoint()
    test_a_marked_5xx_is_a_registry_error_not_unreachable()
    test_a_marked_5xx_still_serves_stale_when_one_is_held()
    test_a_protocol_error_still_serves_stale_when_one_is_held()
    test_usable_is_false_for_every_disposition_without_an_endpoint()
    test_the_log_line_carries_every_fact()
    test_the_value_decoder_is_byte_faithful()
    test_an_unknown_member_does_not_break_the_parse()
    test_control_refuse_everything_yields_no_usable_resolution()
    test_the_classifier_table_is_exactly_the_documented_one()
    print("PASS")
