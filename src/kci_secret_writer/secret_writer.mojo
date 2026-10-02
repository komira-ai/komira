# =============================================================================
# kci_secret_writer/secret_writer.mojo — the `SecretWriter` WRITE-ONLY seam +
#   the `StaticSecretWriter` in-memory test double.
# =============================================================================
#
# THE VERB. A deployed app can have OPERATIONAL secrets whose value the
# deploying party is the authoritative SOURCE of (for example, an SMTP relay
# credential a mail app needs). The deployer must WRITE that value into the
# customer's secret store at ensure-infra so the running app's runtime
# `SecretCapability` resolve finds it. The `SecretStore` trait RESOLVES only —
# it has NO write path (`SecretStore.resolve` is handle-in/value-out; the `put`
# on `StaticSecretStore` belongs to the TEST DOUBLE, not the trait). So the
# write is a separate verb.
#
# THE TYPE-FIREWALL (the single largest trust surface — this is why the verb is
# a SEPARATE TYPE, not a method added to `SecretStore`). `SecretWriter` is a
# DISTINCT trait from the resolve-only `SecretStore`. It is a TYPE-ENFORCED
# boundary, not a policy-only one: a compromised RESOLVE path can never WRITE
# because it structurally does not hold a `SecretWriter` — the runtime-resolve
# path (`SecretCapability` -> `SecretRegistry` -> `SecretStore`) has no path to
# this type, and this type has no `resolve`. Only the applier (the deploy
# control path) holds a `SecretWriter`. This is a stronger guarantee than a
# policy check against a malicious build. It borrows the SHAPE of the
# `SecretMeta`/`SecretValue` capability separation — a read-path
# metadata/value firewall — and applies the same PATTERN to the write side.
#
# WHY NOT WEAKEN `SecretStore` (do NOT add `write` to the resolve trait). Adding a
# `write` method to `SecretStore` would give EVERY holder of the resolve seam —
# including the `SecretCapability` that generated app code holds — a write
# capability. That collapses the firewall the whole trust argument rests on.
# The separation MUST be at the TYPE level; a `SecretWriter` a resolve holder
# cannot obtain is the guarantee.
#
# THE SCOPE LINE (the distinction that must not blur). ONLY *operational*
# secrets the deploying party is the SOURCE of are written. Customer
# *data* secrets stay customer-owned + do-not-read — the deployer never writes
# (or reads) a customer's DB password / API key; those are entered by the
# customer's own tooling. The `SecretWriter` surface does NOT enforce this class
# distinction by type (it cannot know a ref's class); it is enforced by WHO is
# handed a `SecretWriter` (only the operational ensure-infra path) —
# the applier only ever writes refs it authoritatively sources. This is
# documented here so a future caller does not route a customer data secret
# through it.
#
# THE VALUE IS ZEROIZING END-TO-END. The written value is the move-only
# zeroizing `SecretValue` (never a `String`, never logged — the `SecretValue`
# redaction/wipe discipline applies to the WRITE path exactly as it does to
# resolve). `write` consumes the `SecretValue` by value (`var`): the writer moves
# the plaintext into its store call and the source `SecretValue` drops+wipes at
# the end of `write` — no owned copy escapes, no plaintext lingers.
#
# THE WRITE IS VERSIONED / IDEMPOTENT. ensure-secret re-runs on every deploy; a
# re-write of the SAME value must be a no-op-shaped convergence (the customer
# store owns versioning — a cloud secret manager's create-secret-version / a
# Vault KV put). The conformer's `write` is therefore a versioned PUT: writing
# the same value twice is safe (idempotent at the store), and the ROTATION
# invariant — a new value is additive/dual-valid so an already-serving old
# image is never handed a value it did not expect — is the CALLER's contract
# (it writes a NEW version; the old image keeps resolving the pinned prior
# version). The seam itself is a plain versioned PUT.
#
# ENCAPSULATION. The seam surface is value-typed — a `String` (secret_ref, a
# NAME) + a move-only `SecretValue` (the zeroizing value) in, nothing out,
# `raises` for an unreachable / unauthorized store. ZERO UnsafePointer crosses
# the boundary; no wildcard origin; no unsafe_from_address. The value NEVER
# appears in an error / log (the `SecretValue` redaction). The test double's
# interior is a `Dict[String, List[UInt8]]` behind an ArcPointer — flat heap
# fields, no byte-slab, no nested heap-owning struct, so no stale-pointer hazard
# across destroy and recreate.
# =============================================================================

from std.memory import ArcPointer

from komira_secret_store.secret_store import StaticSecretStore
from komira_secret_store.secret_value import SecretValue


# =============================================================================
# §0 — SecretWriter — the WRITE-ONLY seam. A DISTINCT trait from
# `SecretStore` (resolve-only). Only the applier's ensure-infra path holds one.
# =============================================================================
trait SecretWriter(Movable, Deinitable):
    """WRITE a deployer-sourced operational secret VALUE into the
    customer's secret store. A separate verb — the `SecretStore` trait
    resolves only. This is a TYPE-ENFORCED firewall:
    a `SecretWriter` is a SEPARATE type from `SecretStore`, so the runtime-resolve
    path (which holds only a `SecretStore`/`SecretCapability`) structurally cannot
    write. Only the deploy applier's ensure-infra path holds a `SecretWriter`.

    The value is a move-only zeroizing `SecretValue` consumed by value (`var`) —
    the writer moves the plaintext into its store call and the source drops+wipes
    at the end of `write`. An unreachable / unauthorized store RAISES (fail fast
    and loud, never a silent partial). The write is a versioned PUT (the customer
    store owns versioning), so re-writing the SAME value is idempotent at the
    store; the ROTATION dual-valid invariant is the CALLER's
    contract. No UnsafePointer crosses the boundary; the value never appears in an
    error / log (the `SecretValue` redaction).

    THE DEPLOY-CONTEXT BEARER TOKEN. `write` takes a `deploy_token` — a
    plain-`String` bearer token the deploy applier threads so a LIVE conformer can
    PUT the version INTO the CUSTOMER's secret store AS the assumed customer role
    (the deploy principal). A plain `String` (NOT a typed credential): this
    package deliberately depends ONLY on `komira_secret_store`, not on whatever
    application layer mints typed credentials — the write firewall carries no
    application-layer dependency. The token is NEVER a field (custody) — it is a
    per-call param, used within the PUT, and dropped when `write` returns. A local
    conformer (the test double, the self/local path) ignores it."""

    def write(
        mut self,
        secret_ref: String,
        var value: SecretValue,
        deploy_token: String,
    ) raises:
        ...

    def define_container(
        mut self,
        secret_ref: String,
        deploy_token: String,
    ) raises:
        """DEFINE an EMPTY secret CONTAINER (create-if-absent) — NO version
        written. A bootstrap-time deploy admin PRE-DEFINES a secret SLOT so a
        runtime service account can later ADD a version with only
        `secretmanager.versions.add` (never project-wide create). A container that
        already exists is an idempotent no-op. `deploy_token` is the assumed-role
        bearer (per-call, never a field); a local/test conformer ignores it. Distinct
        from `write` (which create-if-absents AND puts a version) — this defines the
        slot WITHOUT ever holding a value, so no plaintext exists at define time."""
        ...

    def has_version(
        mut self,
        secret_ref: String,
        deploy_token: String,
    ) raises -> Bool:
        """Does `secret_ref` already hold at least one usable VERSION? The
        seed-if-absent probe — a caller writes a first value only when this is
        False, so a re-deploy ADOPTS the live version instead of stacking another.

        ★ WHY THIS SITS ON THE WRITE TRAIT AND IS STILL NOT A READ CAPABILITY.
        The obvious probe is AccessSecretVersion, and it is the wrong one: it
        returns the PLAINTEXT, so a `SecretWriter` holding it could read every
        secret it can write — collapsing the firewall this trait exists to BE.
        The live conformer drives ListSecretVersions instead: METADATA only, gated
        by `secretmanager.versions.list` (strictly weaker than `.access`), over a
        response type that has no payload field at all. The answer is one bit and
        the firewall survives by construction rather than by discipline.

        A container that does NOT EXIST answers False (there is nothing to adopt)
        rather than raising — the create-if-absent flow legitimately probes before
        the container exists. Every OTHER failure RAISES, and that split is
        load-bearing: swallowing an unreachable store as False would write a NEW
        version over a live credential during a transient, which is exactly the
        silent-rotation outage this probe exists to prevent. Fail loud, never fail
        open.

        `deploy_token` is the assumed-role bearer — per-call, never a field (the
        same custody rule as `write`). A local/test conformer ignores it."""
        ...


# =============================================================================
# §1 — StaticSecretWriter — an in-memory, scripted WRITE store (the test double).
#
# Mirrors `StaticSecretStore` (the resolve double) but is WRITE-ONLY: it records
# every `write(secret_ref, value)` so a test can assert (a) which refs were
# written, (b) the written value's bytes (via a NON-secret length + a
# byte-equality check — the double copies the bytes out of the SecretValue's
# scoped reader BEFORE it drops), and (c) the write count (the ensure-secret
# idempotence / re-write-is-no-op proofs).
#
# THE DOUBLE HOLDS RAW BYTES, NOT `SecretValue` (deliberate, exactly like the
# resolve double): a `SecretValue` is move-only + zeroizes on drop, so it cannot
# live in a `Dict` a test reads repeatedly. The double copies the plaintext bytes
# out of the SecretValue's `revealed_bytes()` scoped reader into a `List[UInt8]`
# BEFORE the SecretValue drops. This is a TEST DOUBLE; a live conformer never
# holds the plaintext at rest — it PUTs it to the customer store per-write.
#
# THE PAIRED RESOLVE (the write-then-resolve falsifier substrate). The double
# exposes `as_static_store()` — a `StaticSecretStore` seeded with EXACTLY the
# values this writer wrote (keyed by the same secret_ref). This lets an
# ensure-secret falsifier prove the end-to-end property: the applier WRITES via
# the SecretWriter, and the running app's runtime resolve (via a SecretStore over
# the SAME store) then FINDS that value — the write-then-resolve round-trip.
# =============================================================================
struct _StaticWriterState(Movable):
    """The static writer's interior: a `secret_ref -> written-plaintext-bytes`
    map + a running `write_count` + the `last_token` the last write carried (so a
    test asserts the assumed deploy token reached the write), behind an ArcPointer
    so all persist through `share()`. No stale-pointer hazard (a Dict of flat
    `List[UInt8]` value PODs + an Int + a String; no wildcard, no byte-slab)."""

    var written: Dict[String, List[UInt8]]
    var write_count: Int
    var last_token: String
    # DEFINE-ONLY (define_container) bookkeeping — the empty-container defines,
    # distinct from value writes. A `ref -> True` set + a count so a test
    # proves the bootstrap DEFINED the slot WITHOUT writing a value.
    var defined: Dict[String, Bool]
    var define_count: Int
    # ★ PER-REF VERSION COUNT — the thing a real Secret Manager actually moves, and
    # the ONLY honest falsifier for seed-if-absent. `written` is keyed by ref, so a
    # re-write OVERWRITES it: it models `:latest` resolving to the same bytes, which
    # is precisely the property that stays true while a credential silently rotates.
    # A store-side version count only ever GROWS, so a test that asserts THIS is
    # unchanged across two deploys is asserting the real invariant; one that
    # compares `written` bytes would pass on a rotating secret.
    var version_counts: Dict[String, Int]

    def __init__(out self):
        self.written = Dict[String, List[UInt8]]()
        self.last_token = String("")
        self.write_count = 0
        self.defined = Dict[String, Bool]()
        self.define_count = 0
        self.version_counts = Dict[String, Int]()


struct StaticSecretWriter(SecretWriter, Movable):
    """An in-memory `secret_ref -> bytes` `SecretWriter` (the TEST DOUBLE). Proves
    the write seam without a live store: a `write` records the ref + the value
    bytes + bumps a `write_count`; a test asserts WHICH refs were written, the
    written VALUE bytes, and that a re-write of the same value is a store-level
    idempotent PUT (the ensure-secret re-run property). Records a `write_count`.

    The map lives behind an `ArcPointer[_StaticWriterState]` so a `share()`d
    handle reads the AGGREGATE write count + written values off any handle (the
    seam-mock interior-mutation shape, mirroring `StaticSecretStore`)."""

    var _p: ArcPointer[_StaticWriterState]

    def __init__(out self):
        self._p = ArcPointer[_StaticWriterState](_StaticWriterState())

    def __init__(out self, *, var _share: ArcPointer[_StaticWriterState]):
        """Private ctor for `share()` — adopt an existing (copied) ArcPointer."""
        self._p = _share^

    def share(self) -> StaticSecretWriter:
        """A SECOND handle over ONE `_StaticWriterState` (so a test reads the
        aggregate write count + written values off any handle). SAFETY: ArcPointer
        ref-counted shared ownership; a TEST DOUBLE driven on ONE thread (NOT
        concurrent state under a parallelize barrier)."""
        return StaticSecretWriter(
            _share=ArcPointer[_StaticWriterState](copy=self._p)
        )

    def write(
        mut self,
        secret_ref: String,
        var value: SecretValue,
        deploy_token: String,
    ) raises:
        """Record the written value for `secret_ref` + the `deploy_token` it carried
        + bump the write count. Copies the plaintext bytes out of the SecretValue's
        scoped `revealed_bytes()` reader into a `List[UInt8]` BEFORE the moved-in
        `value` drops (+ wipes). A versioned PUT: re-writing the SAME ref OVERWRITES
        (the customer store's create-secret-version semantics — the latest value
        wins). The moved-in `value` drops at the end of this method, securely zeroing
        its buffer (the write path never leaks a plaintext copy — the double copies
        only into its own at-rest bytes, which a live conformer would not do). The
        `deploy_token` is recorded (a test asserts the assumed token reached the
        write) but the double does no cloud call with it."""
        self._p[].write_count += 1
        self._p[].last_token = deploy_token
        var bytes = List[UInt8]()
        var revealed = value.revealed_bytes()
        for i in range(len(revealed)):
            bytes.append(revealed[i])
        self._p[].written[secret_ref] = bytes^
        # A versioned PUT ALWAYS mints a NEW version, even for a byte-identical
        # value. `written` above overwrites (modelling `:latest`); this counter is
        # what a real store moves and what the seed-if-absent falsifier asserts.
        var prior = 0
        if secret_ref in self._p[].version_counts:
            prior = self._p[].version_counts[secret_ref]
        self._p[].version_counts[secret_ref] = prior + 1
        # `value` (the moved-in SecretValue) drops here -> its buffer is zeroed.

    def define_container(
        mut self,
        secret_ref: String,
        deploy_token: String,
    ) raises:
        """Record an empty-container DEFINE for `secret_ref` — NO
        value bytes, distinct from `write`. Bumps `define_count` + records the ref in
        `defined` + the token, so a test proves the bootstrap DEFINED the slot without
        writing a value. Idempotent (a re-define just re-records)."""
        self._p[].define_count += 1
        self._p[].last_token = deploy_token
        self._p[].defined[secret_ref] = True
        # DELIBERATELY does NOT touch `version_counts`. Defining a container mints
        # no version — which is exactly why an `ensure: true` binding with no value
        # produces a container that cannot satisfy a `secret://…:latest` mount, and
        # why `has_version` must answer False here.

    def has_version(
        mut self,
        secret_ref: String,
        deploy_token: String,
    ) raises -> Bool:
        """True iff `secret_ref` holds at least one VERSION. Keys off
        `version_counts`, so a DEFINED-but-empty container (the `ensure: true`,
        no-value shape) correctly answers False and an unknown ref answers False
        (nothing to adopt) rather than raising — mirroring the live conformer's
        NOT_FOUND handling."""
        self._p[].last_token = deploy_token
        if secret_ref not in self._p[].version_counts:
            return False
        return self._p[].version_counts[secret_ref] > 0

    def version_count(self, secret_ref: String) -> Int:
        """How many VERSIONS `secret_ref` holds — the seed-if-absent falsifier.
        Assert THIS across two applies, not the written bytes: `:latest` resolving
        to the same value is exactly what stays true while a credential rotates
        underneath, so a byte comparison cannot see the failure this guards."""
        try:
            if secret_ref not in self._p[].version_counts:
                return 0
            return self._p[].version_counts[secret_ref]
        except:
            return 0

    def define_count(self) -> Int:
        """How many `define_container` (empty-slot) calls were recorded — the
        bootstrap define count, distinct from `write_count`."""
        return self._p[].define_count

    def was_defined(self, secret_ref: String) -> Bool:
        """True iff `secret_ref` was DEFINED as an empty container (no value)."""
        return self._p[].defined.__contains__(secret_ref)

    def write_count(self) -> Int:
        """How many `write` calls were recorded (the ensure-secret idempotence /
        re-write proof — a same-value re-write still bumps this at the SEAM, but
        the ensure-secret CALLER decides whether to skip the write; a test asserts
        the caller's skip via THIS count)."""
        return self._p[].write_count

    def last_token(self) -> String:
        """The `deploy_token` the LAST `write` carried (the assumed customer-role
        bearer token when the applier deploys into a customer environment). A test
        asserts it matches the assumed token — NOT the deployer's own token — proving
        the secret write acted AS the assumed role."""
        return self._p[].last_token

    def was_written(self, secret_ref: String) -> Bool:
        """True iff `secret_ref` has a recorded written value."""
        return self._p[].written.__contains__(secret_ref)

    def written_len(self, secret_ref: String) raises -> Int:
        """The byte length of the value written for `secret_ref` (0 if none). A
        NON-secret length — a length is not the value (the redaction discipline)."""
        if not self._p[].written.__contains__(secret_ref):
            return 0
        return len(self._p[].written[secret_ref])

    def written_equals(self, secret_ref: String, expected: String) raises -> Bool:
        """True iff the value written for `secret_ref` byte-equals `expected` (the
        write-value proof, kept OUT of the redacted path — a TEST-ONLY equality
        the double affords because it holds the at-rest bytes; a live conformer
        never affords this)."""
        if not self._p[].written.__contains__(secret_ref):
            return False
        ref got = self._p[].written[secret_ref]
        var want = expected.as_bytes()
        if len(got) != len(want):
            return False
        for i in range(len(got)):
            if got[i] != want[i]:
                return False
        return True

    def as_static_store(self) raises -> StaticSecretStore:
        """A `StaticSecretStore` (the resolve double) seeded with EXACTLY the
        values this writer wrote, keyed by the same `secret_ref`. This is the
        WRITE-THEN-RESOLVE bridge: the ensure-secret falsifier writes via THIS
        `SecretWriter`, then resolves the same ref via the returned store and
        asserts the value round-trips (the running app's runtime resolve finds
        the deployer-written value). The bytes are copied into
        the store's own script; the two doubles then hold independent copies."""
        var store = StaticSecretStore()
        for ref entry in self._p[].written.items():
            # Reconstruct the value String from the recorded bytes to `put` it into
            # the resolve double (which scripts `secret_ref -> String`).
            var s = String(unsafe_from_utf8=Span(entry.value))
            store.put(entry.key, s)
        return store^
