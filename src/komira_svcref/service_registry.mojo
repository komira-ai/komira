# =============================================================================
# komira_svcref/service_registry.mojo — ServiceRegistry[Store] +
#   ServiceResolver[Store]: the service-reference primitive over a
#   compare-and-swap object store.
# =============================================================================
#
# It replaces DNS / load-balancer discovery: a service registers the URL it
# serves at deploy time under its LOGICAL name, and peers resolve that
# name -> URL from the SAME bucket every node already reads at boot. One object
# per service (`service/<name>` -> URL bytes), keyed BY NAME, so there is ZERO
# cross-service contention — the same shape as git refs on a bucket (one object
# per branch, keyed by name, on the generation-precondition CAS):
#   * read a ref          <->  `resolve(name)`      — `get(<key>)`, 404 -> None.
#   * update a ref        <->  `register(name, url)` — read-etag + CAS.
#   * list refs           <->  `list()`             — `list_with_delimiter`.
# The ONE deliberate divergence from git: a git ref update carries the caller's
# expected OLD sha (the non-fast-forward "fetch first" contract), because a git
# push MUST reject a stale base. A service URL has NO such contract — it changes
# only on a redeploy, and last-writer-wins is the correct policy (the newest
# deploy's URL is the one peers should reach). So `register` does NOT take an
# expected-old; it reads the current etag and CASes, RETRYING ONCE on a 412 (a
# concurrent registrant moved the object between our read and our write).
#
# # register — read-etag + compare_and_swap, retry-once on 412
#
#   * CREATE (object absent): `conditional_put(If-None-Match:*)`. A 412 means a
#     concurrent registrant created it first -> re-read + retry.
#   * UPDATE (object present): read the current etag via `head`, then
#     `compare_and_swap(new-url, <etag>)`. A 412 means a concurrent registrant
#     flipped the URL between our `head` and our CAS -> re-read + retry.
#   One retry is sufficient in practice: registration is a rare (deploy-time)
#   event, so two registrants racing the SAME name is already unlikely, and a
#   double-collision on the retry is vanishingly so. If even the retry 412s we
#   raise (surfacing genuine pathological contention rather than looping).
#
# # On-bucket layout
#
#   key     = "<prefix>/<name>"   e.g. "service/example-api", "service/worker"
#   content = "<url>"             the served URL bytes (a redeploy overwrites)
#
# # ★ THE KEY **IS** THE SERVICE NAME
#
# `_svc_key(name) = "<prefix>/<name>"` and there is NO second composition. A
# service's registry key, its platform service name and its deploy-bundle
# `name:` are ONE string.
#
# ⛔ WHY THERE IS NO REGIONAL KEY COMPOSITION. A writer that composed
# `<prefix>/<name>-<cloud>-<region>` (so that two regional deploys of ONE bundle
# would not overwrite each other's key) produces a key that is not any service's
# name:
#
#     bundle `worker` deployed to a us-central1 environment
#       -> platform service  `worker`
#       -> registry key      `worker-gcp-us-central1`
#
# A peer then authors a reference to `worker-gcp-us-central1` — a KEY in a field
# that names a SERVICE — and the deploy has to DECODE it back to `worker` to
# grant the peer invoke permission. Name the service something else and that
# decode grants permission on a resource that does not exist: **an IAM binding
# on a missing service is not an error any deploy can see, so the deploy is
# GREEN and every call is denied.**
#
# The fix is not a better decoder. It is that a name is a name at every layer.
# A service that must be region-scoped carries the region IN ITS NAME, authored
# once in its bundle (`regional_service_name` composes that name, and
# `regional_service_name_region` reads the region back off it — the ONE
# definition of the convention). The registry does not know what a region is,
# and there is no bare-name ALIAS either: one deploy, one key, one name.
#
# # ServiceResolver — the TTL-cached read-through lookup client
#
# A thin leaf wrapper (OWNS a `ServiceRegistry` + an in-process cache) that a
# service binds at boot (next to the bucket store it already constructs there).
# `resolve(name, now_ms)` returns the cached URL when fresh, else reads through
# the registry and caches with `now_ms + ttl`. The URL changes only on a
# redeploy, so a generous TTL is safe (a peer that redeploys is briefly resolved
# to its prior URL until the TTL lapses or `invalidate` is called). The clock is
# INJECTED as `now_ms` (a caller-supplied monotonic reading) — NOT read from a
# global `Date.now()` — so the cache is fully deterministic under test.
#
# # Encapsulation
#   * No UnsafePointer anywhere; in/out are `String` / `Optional[String]` /
#     `List[String]`.
#   * No wildcard origins, no `unsafe_from_address`, no FFI.
#   * The `Store` is a moved-in generic value; the resolver's cache is a plain
#     `List[_SvcCacheEntry]` of flat-`String` rows.
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import WritePrecondition

from komira_svcref.orphan_reap import (
    OrphanReport,
    ReapOutcome,
    orphan_report,
    refuse_untrustworthy_live_set,
)


# -----------------------------------------------------------------------------
# The CLOUD axis — the ordinals, and the segment they contribute to a NAME.
#
# ★ A regional service name MUST carry its cloud: `worker-us-central1` is
#   ambiguous, `worker-gcp-us-central1` is not. A bare region segment cannot
#   disambiguate `us-central1` on GCP from a region of the same token on
#   AWS / Azure / Kubernetes — a name is only unique inside ONE provider's
#   region namespace, and nothing in a flat `<name>-<region>` key says which.
#
# THE ORDINALS MIRROR the deploy model's `Cloud` proto enum
# (`environment.proto`, package `komira.deploy.v1`). They are mirrored as local
# comptime integers rather than imported because this package is a
# proto-codegen-free object-store leaf: it must not gain a generated-proto
# dependency just to name five integers. A test on the proto side pins the
# two equal.
#
# ⚠ `Cloud` IS THE PROVIDER ENUM — NOT a compute product. A compute product
# (Cloud Run / Lambda / ECS / Kubernetes / a VM) is below the line: two
# products can run on one cloud, and Kubernetes runs on every cloud. A service
# name is addressed by CLOUD.
# -----------------------------------------------------------------------------

comptime CLOUD_UNSPECIFIED: Int = 0
comptime CLOUD_GCP: Int = 1
comptime CLOUD_AWS: Int = 2
comptime CLOUD_AZURE: Int = 3
comptime CLOUD_KUBERNETES: Int = 4
comptime CLOUD_LOCAL: Int = 5


def cloud_segment(cloud: Int) raises -> StaticString:
    """The lowercase CLOUD SEGMENT a regional service name carries — `gcp` /
    `aws` / `azure` / `kubernetes` / `local`.

    These tokens are the short aliases an environment declaration uses for its
    cloud, so a composed segment maps back to the environment that produced it
    without a second table.

    RAISES on UNSPECIFIED and on any unknown ordinal. This is the enforcement
    point of the convention: there is NO fallback segment, because every
    candidate fallback is a lie — an empty segment silently regenerates the
    banned `<name>-<region>` shape, and a placeholder like `unknown` would put a
    key in the bucket that no reader will ever compose. A caller that cannot say
    which cloud it is deploying to has not yet resolved its environment binding,
    and that is a bug in the caller."""
    if cloud == CLOUD_GCP:
        return "gcp"
    if cloud == CLOUD_AWS:
        return "aws"
    if cloud == CLOUD_AZURE:
        return "azure"
    if cloud == CLOUD_KUBERNETES:
        return "kubernetes"
    if cloud == CLOUD_LOCAL:
        return "local"
    raise Error(
        String(
            "service registry: a REGIONAL service name needs a CLOUD segment"
            " and the binding supplied cloud ordinal "
        )
        + String(cloud)
        + String(
            " — expected one of CLOUD_GCP(1)/CLOUD_AWS(2)/CLOUD_AZURE(3)/"
            "CLOUD_KUBERNETES(4)/CLOUD_LOCAL(5). CLOUD_UNSPECIFIED(0) is a"
            " caller that has not resolved its environment binding; resolve it"
            " rather than composing a cloud-less `<name>-<region>` key."
        )
    )


def validate_regional_service_name(
    scoped: String, name: String, region: String
) raises:
    """REFUSE a region-qualified service NAME that carries no cloud segment —
    the convention as an ENFORCED property rather than a remembered one.

    `scoped` is well-formed iff EITHER `region` is empty and `scoped == name`,
    OR `scoped` == `<name>-<segment>-<region>` for a segment `cloud_segment`
    can produce. The banned shape is name, then region, no cloud:
    `worker-us-central1`.

    ⚠ IT RECOMPOSES; IT DOES NOT PARSE. `<base>-<region>` is not parseable back
    in general (`worker-us-central1` splits two ways), so this rebuilds each
    candidate and compares, and never has to guess where a boundary falls.

    ★ ITS CALLER IS THE BUNDLE GATE, NOT A DEPLOY-TIME WRITER. There is no key
    composer (the key IS the name — see the module header), so the shape it
    guards is guarded where the name is AUTHORED: a bundle whose `name:` is
    region-qualified must be well-formed AND must agree with the region it
    deploys into. Raising is deliberately louder than returning a Bool — a
    malformed name is invisible until a second cloud collides with it."""
    if region.byte_length() == 0:
        if scoped != name:
            raise Error(
                String("service registry: regionless name must be bare, got '")
                + scoped
                + String("' for service '")
                + name
                + String("'")
            )
        return
    var clouds = List[Int]()
    clouds.append(CLOUD_GCP)
    clouds.append(CLOUD_AWS)
    clouds.append(CLOUD_AZURE)
    clouds.append(CLOUD_KUBERNETES)
    clouds.append(CLOUD_LOCAL)
    for i in range(len(clouds)):
        var want = (
            name + String("-") + cloud_segment(clouds[i]) + String("-") + region
        )
        if scoped == want:
            return
    raise Error(
        String("service registry: REJECTED cloud-less regional name '")
        + scoped
        + String(
            "' — a regional service name MUST carry its cloud segment:"
            " expected '"
        )
        + name
        + String("-<cloud>-")
        + region
        + String(
            "' (e.g. worker-gcp-us-central1), not '<name>-<region>'. A bare"
            " region cannot disambiguate the same region token across GCP/AWS/"
            "Azure/k8s."
        )
    )


# -----------------------------------------------------------------------------
# The REGION-QUALIFIED SERVICE NAME — a NAME convention, NOT a key composition.
# -----------------------------------------------------------------------------


def regional_service_name(base: String, cloud: Int, region: String) raises -> String:
    """Compose the region-qualified SERVICE NAME `<base>-<cloud>-<region>` — e.g.
    `regional_service_name("worker", CLOUD_GCP, "us-central1")` ->
    `worker-gcp-us-central1`. An EMPTY `region` yields the bare `base`.

    ⚠ READ THIS BEFORE CALLING IT. This function does NOT compose a registry
    key, and NOTHING on the register/resolve path may call it. `_svc_key` is the
    only key composer and it is `"<prefix>/<name>"` — the key IS the name. This
    composes the NAME ITSELF, which is then authored ONCE, in a bundle's `name:`
    field, and thereafter used verbatim as the platform service name, the
    registry key, the peer reference token and the compose graph's node ids.

    Its callers are therefore only the ones that reason ABOUT a name rather
    than with one:
      * the bundle gate, which asserts a region-qualified bundle name agrees
        with the region that bundle actually deploys into; and
      * a deploy-time permission grant that needs a peer's REGION to bind in
        the region the peer actually exists in — via
        `regional_service_name_region`, this function's inverse.

    Using it as the registry's key composer is exactly how a key comes to
    exist that is no service's name. See the module header."""
    if region.byte_length() == 0:
        return String(base)
    return base + String("-") + cloud_segment(cloud) + String("-") + region


def regional_service_name_region(name: String) -> String:
    """The REGION a region-qualified service name carries, or `""` when `name`
    carries none. The INVERSE of `regional_service_name`, and the ONE decoder of
    the convention.

    ★ IT DECIDES BY RECOMPOSING, NEVER BY SPLITTING ON `-`. `worker-us-central1`
    splits two ways (`worker` + `us-central1`, or `worker-us` + `central1`),
    which is why the cloud segment exists: the middle field is drawn from a
    CLOSED five-value set, so this scans for `-<segment>-` and returns what
    follows. A name with no such infix — `example-api`, `scheduler` — returns
    `""`, and can never be read as a region.

    ⚠ THE TRAILING FIELD MUST BE NON-EMPTY: `worker-gcp-` is not a
    region-qualified name (an empty region composes the BARE name by
    construction, so the composer cannot emit that token).

    ⚠ THIS IS DELIBERATELY NOT PARAMETRIC IN A SERVICE NAME: any service may be
    region-qualified, and there is one cloud-segment list, here.

    ⚠ PREFER A BINDING OVER A DECODE. A caller that holds the deployment's own
    environment binding should read the region from it. Decoding a NAME is for
    the cases where the name is the only thing available — a fleet of peers
    declared by name, or a peer that another bundle places, for which this
    deploy holds no binding at all."""
    var segs = List[Int]()
    segs.append(CLOUD_GCP)
    segs.append(CLOUD_AWS)
    segs.append(CLOUD_AZURE)
    segs.append(CLOUD_KUBERNETES)
    segs.append(CLOUD_LOCAL)
    for i in range(len(segs)):
        var infix: String
        try:
            infix = String("-") + cloud_segment(segs[i]) + String("-")
        except:
            continue  # unreachable: every ordinal above is a named cloud
        var at = name.find(infix)
        if at > 0:
            var tail = String(name[byte = at + infix.byte_length() :])
            if tail.byte_length() > 0:
                return tail^
    return String("")
# -----------------------------------------------------------------------------
# URL encode / decode — the served URL bytes (no framing; a bare URL string).
# -----------------------------------------------------------------------------


def _encode_url(url: String) -> List[UInt8]:
    """The stored object bytes for a service URL: the bare URL bytes (no
    trailing newline — a service URL is not a line-oriented git ref file)."""
    var b = url.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _decode_url(bytes: List[UInt8]) -> String:
    """Parse the stored object bytes back to the URL string, stripping any
    trailing whitespace / newline a tool may have appended (defensive — a bare
    write via `_encode_url` adds none)."""
    var end = len(bytes)
    while end > 0:
        var c = bytes[end - 1]
        if c == UInt8(10) or c == UInt8(13) or c == UInt8(32) or c == UInt8(9):
            end -= 1
        else:
            break
    var out = String("")
    for i in range(end):
        out += chr(Int(bytes[i]))
    return out^


# -----------------------------------------------------------------------------
# Error taxonomy probes (the store raises Error(msg) whose text carries the
# HTTP-status taxonomy arm).
# -----------------------------------------------------------------------------


def _is_precondition_failed(e: Error) -> Bool:
    """True iff `e` is a conditional-write precondition failure (412) — the
    stale-CAS / create-collision that `register` retries once on.

    Matches the CANONICAL uppercase `StoreError[PRECONDITION]` taxonomy token
    FIRST — the token the object-store conformers emit. This package is a
    clean object-store leaf, so it classifies in-leaf rather than depending on
    a transport's own classifier. Keying ONLY on lowercase `precondition` or
    the numeric `412` would be dead against the uppercase token, and a message
    that carried no numeric would silently turn a concurrent-deploy 412 into a
    fatal register (no retry). The mixed-case / numeric substrings are kept
    for the XML-conformer and generic error shapes."""
    var msg = String(e)
    return (
        msg.find("StoreError[PRECONDITION]") >= 0
        or msg.find("precondition") >= 0
        or msg.find("Precondition") >= 0
        or msg.find("PreconditionFailed") >= 0
        or msg.find("412") >= 0
    )


def _is_not_found(e: Error) -> Bool:
    """True iff `e` is a store not-found (404) — an absent service object.

    Matches the CANONICAL uppercase `StoreError[NOT_FOUND]` taxonomy token
    FIRST. Keying ONLY on lowercase `not_found` or the numeric `404` would be
    dead against the uppercase token, and a message that carried no numeric
    would silently turn a first-deploy 404 (the object-absent path `register`
    must take to CREATE) into a fatal register. Mixed-case / numeric /
    `NoSuchKey` substrings are kept for the other conformers' shapes."""
    var msg = String(e)
    return (
        msg.find("StoreError[NOT_FOUND]") >= 0
        or msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("NoSuchKey") >= 0
        or msg.find("404") >= 0
    )


# =============================================================================
# ServiceRegistry[Store] — service-name -> URL over the CAS object store.
# =============================================================================
struct ServiceRegistry[Store: ConditionalWriteStore](Movable):
    """The service registry over a `ConditionalWriteStore`'s compare-and-swap.
    Owns the moved-in `Store` + a key prefix (default `"service"`). Services
    are keyed BY NAME (one object per service = zero cross-service
    contention). Portable by inheritance from the `Store` type-param — the
    SAME code runs on the in-memory conformer (tests) and S3 / GCS (a live
    bucket)."""

    var _store: Self.Store
    var _prefix: String

    def __init__(out self, var store: Self.Store):
        """Construct over `store` with the default `"service"` key prefix."""
        self._store = store^
        self._prefix = String("service")

    def __init__(out self, var store: Self.Store, var prefix: String):
        """Construct over `store` with an explicit key `prefix` (e.g. to
        namespace multiple registries in one shared bucket)."""
        self._store = store^
        self._prefix = prefix^

    def into_store(deinit self) -> Self.Store:
        """Recover the underlying store (e.g. to share the backing handle)."""
        return self._store^

    @always_inline
    def prefix(self) -> String:
        """The key prefix all services live under (`<prefix>/<name>`)."""
        return String(self._prefix)

    @always_inline
    def _svc_key(self, name: String) -> String:
        """The object key for service `name`: `<prefix>/<name>`."""
        return self._prefix + String("/") + name

    def _name_from_key(self, key: String) raises -> String:
        """Strip the `<prefix>/` head from a stored key back to the service
        name (the inverse of `_svc_key`).

        ⛔ IT VERIFIES THE HEAD, NOT MERELY THE LENGTH. A length check is
        sound for `list`, whose keys come back from a prefix-scoped listing and
        therefore cannot be foreign, and WRONG the moment a key arrives from
        outside: under prefix `service`, `staged-image/example-api` is longer
        than `service/` and would decode to the name `image/example-api` — a
        name that is no service's, silently derived from ANOTHER registry's
        namespace. The public key-addressed verbs (`name_for_key` /
        `resolve_key` / `deregister_key`) are exactly that outside caller, and
        one of them deletes."""
        var head = self._prefix + String("/")
        var hb = head.as_bytes()
        var kb = key.as_bytes()
        if len(kb) <= len(hb):
            raise Error(
                String("ServiceRegistry: key '")
                + key
                + String("' is not a key under this registry's prefix '")
                + head
                + String(
                    "' (too short to carry a name). A registry key is"
                    " `<prefix>/<name>`; a bare name is not a key."
                )
            )
        for i in range(len(hb)):
            if kb[i] != hb[i]:
                raise Error(
                    String("ServiceRegistry: key '")
                    + key
                    + String("' is NOT under this registry's prefix '")
                    + head
                    + String(
                        "'. Refusing to decode it: a key from another"
                        " namespace (`staged-image/…`, `staged-content/…`)"
                        " would otherwise yield a name this registry never"
                        " wrote, and the verbs that ride this delete."
                    )
                )
        var out = String("")
        for i in range(len(hb), len(kb)):
            out += chr(Int(kb[i]))
        return out^

    def name_for_key(self, key: String) raises -> String:
        """The service NAME a full object key addresses — the public inverse of
        `_svc_key`, REFUSING any key not under this registry's prefix.

        ★ IT EXISTS BECAUSE THE OPERATOR-FACING ADDRESS IS A KEY, NOT A NAME.
        An operator reaping an entry types `service/worker-us-south1` (it is
        what a bucket listing shows), while every verb on this type takes a
        NAME and composes the key itself. Passing a key where a name is
        expected composes `service/service/worker-us-south1`, which resolves to
        nothing — an address that reads as "already absent" for a key that is
        very much present."""
        return self._name_from_key(key)

    # =========================================================================
    # register — publish `name -> url`; read-etag + CAS, retry-once on 412.
    # =========================================================================
    def register(mut self, name: String, url: String) raises:
        """Register (or re-register on redeploy) service `name` at `url`.

        Last-writer-wins: a redeploy's URL overwrites the prior one. Reads the
        current etag (via `head`) and `compare_and_swap`es on it — or
        `conditional_put(If-None-Match:*)` if the object is absent — RETRYING
        ONCE on a 412 (a concurrent registrant moved the object between our read
        and our write). Raises only on a non-precondition store error, or if
        even the single retry 412s (genuine pathological contention)."""
        var path = Path.parse(self._svc_key(name))
        var bytes = _encode_url(url)

        # First attempt. `_try_write` returns True on commit, False on a 412.
        if self._try_write(path, bytes):
            return
        # One retry: a concurrent registrant won the race; re-read the fresh
        # etag and try once more. Last-writer-wins => this is expected to win.
        if self._try_write(path, bytes):
            return
        raise Error(
            "ServiceRegistry.register: persistent CAS contention on '"
            + name
            + "' (412 twice) — retry the deploy"
        )

    # =========================================================================
    # register_if_changed — resolve-and-compare; SKIP the head+CAS entirely when
    # the stored URL already equals the observed one (idempotent skip).
    # =========================================================================
    def register_if_changed(mut self, name: String, url: String) raises -> Bool:
        """Register `name -> url` ONLY when it differs from what is already stored.

        `register` as-is ALWAYS does a head + CAS (it is never a no-op). A
        LEVEL-TRIGGERED caller — e.g. a reconcile loop that re-registers on every
        health-gate advance — would then emit a steady bucket write stream AND
        can exhaust `register`'s retry-once budget racing a concurrent registrant
        on the SAME key (e.g. a deploy CLI writing the same `service/<name>`).
        So this first `resolve`s the current URL and SKIPS the write ENTIRELY
        when it already equals `url`: a steady-state redeploy to the SAME url
        becomes a PURE READ — no `head`, no CAS. Only a genuine URL change (or an
        absent object) falls through to `register` (head + CAS, retry-once).

        Returns True iff a write was issued (the URL changed or was absent), False
        on the pure-read skip (unchanged). RAISES on a genuine store error (fail
        loud) — same fail-loud contract as `register`."""
        var cur = self.resolve(name)
        if cur and cur.value() == url:
            return False  # unchanged — pure read, no head, no CAS
        self.register(name, url)
        return True

    def _try_write(self, path: Path, bytes: List[UInt8]) raises -> Bool:
        """One read-etag + conditional-write cycle. Returns True on commit,
        False on a 412 (the caller retries). Reads the current etag via `head`;
        an absent object (404) takes the create-if-absent path, a present one
        takes the If-Match CAS path."""
        # Read the current etag. Absent (404) -> None -> create-if-absent.
        var cur_etag = Optional[String]()
        try:
            var meta = self._store.head(path)
            cur_etag = Optional[String](meta.etag)
        except e:
            if not _is_not_found(e):
                raise e^  # a real error (auth / transport) is not our 404

        if not cur_etag:
            # CREATE: create-if-absent. A 412 means a concurrent create won.
            try:
                _ = self._store.conditional_put(
                    path, bytes, WritePrecondition.if_none_match_star()
                )
                return True
            except e:
                if _is_precondition_failed(e):
                    return False
                raise e^

        # UPDATE: compare_and_swap on the etag we just read. A 412 means a
        # concurrent registrant flipped the URL between our head and our CAS.
        try:
            _ = self._store.compare_and_swap(path, bytes, cur_etag.value())
            return True
        except e:
            if _is_precondition_failed(e):
                return False
            raise e^

    # =========================================================================
    # resolve — read the URL for `name` (or None if unregistered).
    # =========================================================================
    def resolve(self, name: String) raises -> Optional[String]:
        """Resolve service `name` to its registered URL, or `None` if no
        service is registered under that name. A store not-found (404) is
        `None`, not a raise. This is the DNS-replacement read: a peer resolves
        `name` -> URL instead of a hostname -> IP."""
        var path = Path.parse(self._svc_key(name))
        try:
            var bytes = self._store.get(path)
            return Optional[String](_decode_url(bytes))
        except e:
            if _is_not_found(e):
                return Optional[String]()
            raise e^

    # =========================================================================
    # list — every registered service name (the registry catalog).
    # =========================================================================
    def list(self) raises -> List[String]:
        """List every registered service name (the `<prefix>/` catalog). The
        order follows the store's listing order; callers that need a stable
        order should sort. Empty when nothing is registered."""
        var prefix_path = Path.parse(self._prefix + String("/"))
        var res = self._store.list_with_delimiter(prefix_path)
        var out = List[String]()
        for i in range(len(res.objects)):
            out.append(self._name_from_key(res.objects[i].location))
        return out^

    # =========================================================================
    # resolve_key / deregister / deregister_key — the DELETE half.
    # =========================================================================
    def resolve_key(self, key: String) raises -> Optional[String]:
        """Resolve a FULL OBJECT KEY (`<prefix>/<name>`) to its URL — `resolve`
        for a caller holding the operator-facing address. REFUSES a key under
        another prefix (see `name_for_key`); `None` means the key is absent."""
        return self.resolve(self.name_for_key(key))

    def deregister(mut self, name: String) raises -> Bool:
        """⛔ THE DELETE VERB. Remove service `name` from the registry.

        Returns True iff an object was actually deleted, False if the entry was
        ALREADY ABSENT. Absent is not an error: a reap is a cleanup, and a
        cleanup that is re-run after a partial failure must land on its
        post-condition and report success.

        ⚠ NO CAS, DELIBERATELY. `register` CASes because two registrants can
        race for one name and the LAST writer must win. A delete has no such
        contract: there is one value to remove and removing it twice is removing
        it once. A CAS here would instead introduce a failure mode that does not
        exist — a delete that 412s because a redeploy re-registered between the
        head and the delete — and the correct handling of that is to NOT delete,
        which is what a caller gets by re-running the report.

        ⚠ AND IT IS DELIBERATELY UNCONDITIONAL ABOUT LIVENESS. This method knows
        nothing about whether `name` is deployed; that judgement lives in
        `reap_orphans` (and in whatever ownership refusal the calling tool
        applies). A primitive that silently declined to delete a name it
        decided was live would be un-auditable — the refusals are explicit,
        above this, and they raise."""
        var path = Path.parse(self._svc_key(name))
        # Presence probe FIRST so the return value distinguishes "deleted" from
        # "was already gone" — object-store `delete` is idempotent and the
        # conformers do not agree on whether an absent delete raises.
        try:
            _ = self._store.head(path)
        except e:
            if _is_not_found(e):
                return False
            raise e^
        try:
            self._store.delete(path)
        except e:
            if _is_not_found(e):
                return False  # raced with another reap — same post-condition
            raise e^
        return True

    def deregister_key(mut self, key: String) raises -> Bool:
        """`deregister` addressed by a FULL OBJECT KEY (`<prefix>/<name>`) — the
        form an operator holds. REFUSES a key under another prefix; otherwise
        identical to `deregister`, idempotence included."""
        return self.deregister(self.name_for_key(key))

    # =========================================================================
    # orphan_scan / reap_orphans — the REPORT (free) and the REAP (explicit).
    # =========================================================================
    def orphan_scan(self, live: List[String]) raises -> OrphanReport:
        """Diff this registry's catalog against `live` (the caller's live
        deployment enumeration) — see `orphan_reap.orphan_report`.

        A READ. It lists and returns; it never deletes and never raises on a
        bad diff, because an operator must be able to LOOK at a diff that is
        not safe to act on. The judgement is in `reap_orphans`.

        ⚠ THE LIVE SET IS AN INPUT, NEVER DERIVED HERE. This package is a clean
        object-store leaf: it has no cloud client and must not grow one. Who is
        live is a question for whoever holds a deploy API, and keeping it a
        parameter is also what makes the whole path testable against a fake
        store with no cloud call at all."""
        return orphan_report(self.list(), live)

    def reap_orphans(
        mut self, live: List[String], apply: Bool
    ) raises -> ReapOutcome:
        """Remove every registry entry with no live deployment behind it.

        ★ PLAN BY DEFAULT. With `apply=False` this DELETES NOTHING and returns
        the plan (`planned` populated, `deleted` empty) — deliberately what you
        get if you forget which mode you meant.

        ⛔ AND IT REFUSES AN UNTRUSTWORTHY LIVE SET BEFORE IT DELETES ANYTHING —
        an empty enumeration, or one that shares no name with the catalog. Both
        arms and their reasons are in `orphan_reap.refuse_untrustworthy_live_set`;
        both would otherwise present as "everything is an orphan" and take the
        whole registry with a green exit.

        ⚠ The refusal fires on a PLAN too. A plan whose input cannot authorise a
        delete is not a preview of anything — printing a list of reapable names
        and then refusing the apply teaches the operator to reach for the flag.
        Use `orphan_scan` when you want the report regardless; it never
        raises."""
        var report = orphan_report(self.list(), live)
        refuse_untrustworthy_live_set(report)

        var planned = List[String]()
        for i in range(len(report.orphans)):
            planned.append(String(report.orphans[i]))
        var deleted = List[String]()
        if not apply:
            return ReapOutcome(planned^, deleted^, False)
        for i in range(len(report.orphans)):
            if self.deregister(report.orphans[i]):
                deleted.append(String(report.orphans[i]))
        return ReapOutcome(planned^, deleted^, True)


# =============================================================================
# ServiceResolver[Store] — the TTL-cached read-through lookup client.
# =============================================================================


@fieldwise_init
struct _SvcCacheEntry(Copyable, Movable, Deinitable):
    """One cached `name -> (url, expiry_ms)` row. Flat Strings + a scalar (a
    typed List element, not a byte-slab)."""

    var name: String
    var url: String
    var expiry_ms: Int64


struct ServiceResolver[Store: ConditionalWriteStore](Movable):
    """A TTL-cached read-through lookup client over a `ServiceRegistry[Store]`.

    OWNS the moved-in registry + a small in-process cache. `resolve(name,
    now_ms)` returns the cached URL when fresh (`expiry_ms > now_ms`), else
    reads through the registry and caches with `now_ms + ttl_ms`. A generous
    TTL is safe because a service URL changes only on redeploy; `invalidate`
    (or a lapsed TTL) picks up the new URL.

    THE CLOCK IS INJECTED: every op takes `now_ms` (a caller-supplied monotonic
    reading), so the cache is fully deterministic under test — there is no
    hidden `Date.now()`. Each service reads its own clock and passes it in (it
    already runs an event loop with a time source at boot).

    A thin leaf: no reactor, no runtime, no I/O of its own beyond the registry
    read-through — so any service can bind one next to the bucket store it
    already constructs at boot."""

    var _registry: ServiceRegistry[Self.Store]
    var _ttl_ms: Int64
    var _cache: List[_SvcCacheEntry]

    def __init__(
        out self, var registry: ServiceRegistry[Self.Store], ttl_ms: Int64
    ):
        """Construct over a moved-in `registry` with a `ttl_ms` cache lifetime
        (milliseconds). A larger TTL trades staleness-on-redeploy for fewer
        bucket reads; `invalidate` forces a re-read on the next resolve."""
        self._registry = registry^
        self._ttl_ms = ttl_ms
        self._cache = List[_SvcCacheEntry]()

    def into_registry(deinit self) -> ServiceRegistry[Self.Store]:
        """Recover the wrapped registry (e.g. to register through it)."""
        return self._registry^

    def registry(ref self) -> ref [self._registry] ServiceRegistry[Self.Store]:
        """Borrow the wrapped registry (e.g. to `register` this service's own
        URL at boot, before entering the resolve loop)."""
        return self._registry

    @always_inline
    def ttl_ms(self) -> Int64:
        """The cache TTL in milliseconds."""
        return self._ttl_ms

    def _find(self, name: String) -> Int:
        """Index of `name` in the cache, or -1 (linear scan — the cache holds
        one row per peer service, a handful of entries)."""
        for i in range(len(self._cache)):
            if self._cache[i].name == name:
                return i
        return -1

    # =========================================================================
    # resolve — cached read-through; `now_ms` is the injected clock reading.
    # =========================================================================
    def resolve(
        mut self, name: String, now_ms: Int64
    ) raises -> Optional[String]:
        """Resolve `name` -> URL, serving the cache when fresh. If a cached
        entry exists and `expiry_ms > now_ms`, return it WITHOUT touching the
        registry. Otherwise read through `registry.resolve`, cache the result
        (with `expiry_ms = now_ms + ttl_ms`), and return it. Returns `None`
        (and caches nothing) when the service is unregistered."""
        var idx = self._find(name)
        if idx >= 0 and self._cache[idx].expiry_ms > now_ms:
            return Optional[String](String(self._cache[idx].url))  # fresh hit

        # Miss / stale -> read through the registry (the bucket).
        var got = self._registry.resolve(name)
        if not got:
            return Optional[String]()  # unregistered — do NOT cache a negative

        var url = got.value()
        var exp = now_ms + self._ttl_ms
        if idx >= 0:
            self._cache[idx].url = String(url)
            self._cache[idx].expiry_ms = exp
        else:
            self._cache.append(_SvcCacheEntry(String(name), String(url), exp))
        return Optional[String](String(url))

    def invalidate(mut self, name: String):
        """Drop `name` from the cache so the next `resolve` reads through
        (call after learning a peer redeployed, to pick up its new URL before
        the TTL lapses)."""
        var keep = List[_SvcCacheEntry]()
        for i in range(len(self._cache)):
            if self._cache[i].name != name:
                keep.append(self._cache[i].copy())
        self._cache = keep^

    def clear(mut self):
        """Drop every cached entry (e.g. on a bucket-wide config change)."""
        self._cache = List[_SvcCacheEntry]()

    @always_inline
    def cache_len(self) -> Int:
        """The number of cached entries (test / introspection helper)."""
        return len(self._cache)
