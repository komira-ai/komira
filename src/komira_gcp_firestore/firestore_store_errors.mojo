# =============================================================================
# komira_gcp_firestore/firestore_store_errors.mojo — Firestore -> StoreError
#   TAXONOMY. The half of the Firestore `ConditionalWriteStore` conformer that
#   is not mechanical.
# =============================================================================
#
# ★ THE CAS PRIMITIVES ARE THE EASY HALF. `create_if_absent` and
# `update_if_unchanged` already exist on `FirestoreClient` and map 1:1 onto the
# trait's two preconditions. WHAT KILLS THIS CONFORMER IS THE ERROR TAXONOMY:
# every consumer of a `ConditionalWriteStore` decides "was that a CAS conflict?"
# and "was that an absent object?" BY READING THE ERROR MESSAGE, and a 412 that
# is not re-emitted in the vocabulary they read turns an ordinary
# concurrent-deploy retry into a fatal write failure.
#
# The two classifiers this module is written against — copied here verbatim so
# the thing being satisfied is visible next to the thing satisfying it — are
# `komira_service_registry/directory.mojo`'s:
#
#     _is_precondition_failed(e):  "StoreError[PRECONDITION]" | "precondition"
#                                  | "Precondition" | "PreconditionFailed" | "412"
#     _is_not_found(e):            "StoreError[NOT_FOUND]" | "not_found"
#                                  | "NotFound" | "NoSuchKey" | "404"
#
# and `komira_objectstore/cas_manifest`'s `_is_precondition`, which is the same
# substring shape. The GCS store (`komira_objectstore_gcs`,
# `gcs_store_error_from_code`) raises the same contract, and this module
# matches it exactly:
#
#     StoreError[<KIND>] <what> status=<http>
#
# so a caller cannot tell a Firestore-backed store from a GCS-backed one by the
# shape of a raised error. THAT is the drop-in property.
#
# =============================================================================
# ⛔ THE TRAP THIS MODULE EXISTS TO CLOSE — AND IT IS NOT THE 412.
# =============================================================================
#
# Both classifiers above are **OR over substrings of the WHOLE message**. There
# is no first-match-wins and no field discipline: ANY occurrence of `404`
# ANYWHERE in the string makes the message read as an absent object, and any
# occurrence of `Precondition` makes it read as a lost CAS race. So the danger
# is not the arm you forget to map — it is the arm you map correctly and then
# DESCRIBE using a word that means something else to the reader.
#
# Firestore walks straight into it, twice, because two of its PERMANENT
# configuration faults are spelled with the tokens for the two RETRYABLE /
# ORDINARY outcomes:
#
#   * `FirestoreDatabaseAbsent:` — the configured DATABASE does not exist. It is
#     an HTTP **404** whose body says **NOT_FOUND**. Pass that text through and
#     `_is_not_found` fires: every lookup answers "not registered", the serving
#     app returns `200 {"found":false}` forever, and the registry reports an
#     empty world instead of a broken deploy. (This is the same conflation that
#     let a service run for days against a database that did not exist; see
#     `FIRESTORE_DATABASE_ABSENT_PREFIX`'s own comment.)
#   * `FirestoreDatabasePrecondition:` — a missing COMPOSITE INDEX. The token
#     `Precondition` is IN THE SENTINEL'S OWN NAME. Pass it through and
#     `_is_precondition_failed` fires: `publish_endpoint` reads a permanent
#     database fault as a lost CAS race, retries once, fails identically, and
#     raises "persistent CAS contention — retry the deploy". The diagnosis is
#     wrong, the remedy printed to the operator is wrong, and the real cause
#     (apply an index) is never named.
#
# Neither is hypothetical and neither is caught by mapping the 412 correctly.
#
# THE FIX IS STRUCTURAL, IN TWO PARTS:
#
#   1. CLASSIFY ON THE PREFIX, NEVER ON A SUBSTRING. `FirestoreClient` raises
#      five TYPED sentinels, each tested with `_has_prefix`, and the five
#      prefixes are pairwise disjoint. So classification here is a decision
#      procedure, not a heuristic — no ordering hazard, no overlap, and a
#      message that is none of the five falls to the generic HTTP-status arm.
#
#   2. DEFUSE THE TAIL. Everything variable in the emitted message (the op, the
#      resource, the client's own error with Firestore's HTTP status) is run
#      through `defuse_classifier_tokens`, which rewrites each of the ten
#      classifier tokens into a bracket-interrupted spelling a human reads
#      identically and `find()` does not match (`404` -> `4[0]4`,
#      `Precondition` -> `P[r]econdition`). The ONLY classifier-visible content
#      left in the message is the canonical head `StoreError[<KIND>]` and the
#      trailing `status=<http>` — and BOTH are generated from the KIND, never
#      copied from the input.
#
#      ⚠ Defusing the tail rather than dropping it is deliberate: the
#      client's error names the operation, the document, the method, the HTTP
#      status and the google.rpc.Code, which is what an operator acts on. (It
#      carries no byte of Google's `error.message`: the generated client keeps
#      none, because that text names projects and documents.) A diagnostic
#      that is readable but not machine-confusable beats a correct message
#      nobody can act on.
#
#   3. AND THEN CHECK IT. `message_class_is_exactly` re-implements the two
#      classifiers and `map_firestore_error_to_store_error` runs the composed
#      message through them BEFORE returning: if the message carries any family
#      other than its own kind's, the tail is discarded and a minimal, provably
#      unambiguous form is emitted instead. So "the mapping cannot lie" is a
#      property of the code path, not of this comment.
#
# ⚠ THE RESOURCE IS DEFUSED TOO, AND THAT IS NOT PARANOIA. The resource is
# `<collection>/<doc>` and the doc id is a caller-supplied SERVICE NAME. A
# service named `404` would otherwise turn every TRANSPORT error about it into
# an absent-object verdict.
#
# Encapsulation: pure value functions over String / Error. ZERO UnsafePointer,
# ZERO wildcard origins, ZERO unsafe_from_address, ZERO FFI.
# =============================================================================

from .firestore_client import (
    is_already_exists_error,
    is_database_absent_error,
    is_database_precondition_error,
    is_not_found_error,
    is_precondition_failed_error,
)


# -----------------------------------------------------------------------------
# §1 — The StoreError kind vocabulary. IDENTICAL to the GCS taxonomy
#      (`komira_objectstore_gcs`: `gcs_store_error_from_code`,
#      `gcs_store_error_kind_from_message`) so the two backends are
#      indistinguishable to a caller.
# -----------------------------------------------------------------------------

comptime STORE_KIND_PRECONDITION: StaticString = "PRECONDITION"
comptime STORE_KIND_NOT_FOUND: StaticString = "NOT_FOUND"
comptime STORE_KIND_PERMISSION_DENIED: StaticString = "PERMISSION_DENIED"
comptime STORE_KIND_THROTTLED: StaticString = "THROTTLED"
comptime STORE_KIND_TRANSPORT: StaticString = "TRANSPORT"
comptime STORE_KIND_MALFORMED: StaticString = "MALFORMED"


def store_kind_to_http(kind: String) -> Int:
    """The HTTP-status analog of a StoreError kind token. Byte-identical to the
    GCS conformer's mapping — a caller reading `status=` off either backend gets
    the same number for the same condition."""
    if kind == String(STORE_KIND_PRECONDITION):
        return 412
    if kind == String(STORE_KIND_NOT_FOUND):
        return 404
    if kind == String(STORE_KIND_PERMISSION_DENIED):
        return 403
    if kind == String(STORE_KIND_THROTTLED):
        return 429
    if kind == String(STORE_KIND_TRANSPORT):
        return 500
    return 400


# -----------------------------------------------------------------------------
# §2 — The classifier tokens, and the defuser.
#
# ⛔ THIS LIST IS A COPY OF SOMEBODY ELSE'S PREDICATE. If `directory.mojo` or
# `cas_manifest` ever adds a token, this list must gain it or a message can once
# again be read as something it is not. `test_firestore_conditional_store.mojo`
# pins the list against BOTH classifiers by re-implementing them from the same
# ten strings, which is the closest a copy can come to being checked.
# -----------------------------------------------------------------------------

comptime _N_TOKENS: Int = 10


def _token(i: Int) -> StaticString:
    """The i-th classifier token, LONGEST FIRST.

    Longest-first matters because the scan is greedy at each position: with
    `precondition` ahead of `PreconditionFailed` the shorter token would be
    consumed first and leave a defused-but-still-matching remainder.

    ⛔ THE RETURN TYPE IS `StaticString`, AND IT IS NOT A STYLE CHOICE. A ladder
    returning `String` literals lowers to two parallel (pointer, length)
    constant arrays whose two call-site references an `--emit shared-lib` link
    binds INDEPENDENTLY; a shipped shared library bound such a pair
    CROSSED and crashed its host process. `StaticString` is the measured-safe
    form.

    ⚠ THIS FUNCTION WAS WRITTEN AS A `-> String` LADDER AND SHIPPED A COMMENT
    CLAIMING IT AVOIDED THAT HAZARD "by being an index function rather than a
    List literal". It did not; the lint named it on the first run. Recorded
    here rather than quietly deleted, because a comment asserting a property
    the code does not have is worse than no comment: it is what stops the next
    reader from checking."""
    if i == 0:
        return "StoreError[PRECONDITION]"
    if i == 1:
        return "StoreError[NOT_FOUND]"
    if i == 2:
        return "PreconditionFailed"
    if i == 3:
        return "precondition"
    if i == 4:
        return "Precondition"
    if i == 5:
        return "NoSuchKey"
    if i == 6:
        return "not_found"
    if i == 7:
        return "NotFound"
    if i == 8:
        return "404"
    return "412"


def _matches_at(hay: List[UInt8], at: Int, needle: String) -> Bool:
    """Byte-exact `hay[at:at+len(needle)] == needle`."""
    var nb = needle.as_bytes()
    if at + len(nb) > len(hay):
        return False
    for j in range(len(nb)):
        if hay[at + j] != nb[j]:
            return False
    return True


def _defused_form(tok: String) -> String:
    """`X[y]Z…` — the token with a bracket inserted after its first byte.

    A human reads `4[0]4` as 404 and `P[r]econdition` as Precondition; a
    `find()` for either token does not match. Every classifier token is at
    least 3 bytes, so this is always well-defined."""
    var tb = tok.as_bytes()
    var out = String("")
    out += chr(Int(tb[0]))
    out += String("[")
    out += chr(Int(tb[1]))
    out += String("]")
    for i in range(2, len(tb)):
        out += chr(Int(tb[i]))
    return out^


def defuse_classifier_tokens(s: String) -> String:
    """Rewrite every occurrence of a StoreError classifier token in `s` into a
    bracket-interrupted spelling that reads the same and matches nothing.

    This is what lets the emitted error carry Google's own diagnostic prose —
    the sentence naming the missing index and the console URL that creates it —
    without that prose being able to change the message's CLASS."""
    var bs = s.as_bytes()
    var buf = List[UInt8](capacity=len(bs))
    for i in range(len(bs)):
        buf.append(bs[i])
    var out = String("")
    var i = 0
    while i < len(buf):
        var hit = -1
        for t in range(_N_TOKENS):
            if _matches_at(buf, i, String(_token(t))):
                hit = t
                break
        if hit >= 0:
            var tok = String(_token(hit))
            out += _defused_form(tok)
            i += tok.byte_length()
        else:
            out += chr(Int(buf[i]))
            i += 1
    return out^


def defusing_changed(s: String) -> Bool:
    """True iff `s` carries at least one classifier token — i.e. iff
    `defuse_classifier_tokens` would rewrite it. Used to decide whether the
    emitted message states that a rewrite happened (a silent rewrite of an
    operator-facing string is its own small lie)."""
    for t in range(_N_TOKENS):
        if s.find(String(_token(t))) >= 0:
            return True
    return False


# -----------------------------------------------------------------------------
# §3 — The SELF-CHECK. The two consumer classifiers, re-implemented.
# -----------------------------------------------------------------------------


def store_error_says_precondition(msg: String) -> Bool:
    """`komira_service_registry/directory.mojo:_is_precondition_failed`, verbatim
    — the predicate the emitted message will be read by."""
    return (
        msg.find("StoreError[PRECONDITION]") >= 0
        or msg.find("precondition") >= 0
        or msg.find("Precondition") >= 0
        or msg.find("PreconditionFailed") >= 0
        or msg.find("412") >= 0
    )


def store_error_says_not_found(msg: String) -> Bool:
    """`komira_service_registry/directory.mojo:_is_not_found`, verbatim."""
    return (
        msg.find("StoreError[NOT_FOUND]") >= 0
        or msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("NoSuchKey") >= 0
        or msg.find("404") >= 0
    )


def message_class_is_exactly(msg: String, kind: String) -> Bool:
    """True iff `msg` is read by the consumer classifiers as EXACTLY the family
    `kind` belongs to, and no other.

    PRECONDITION must be read as a conflict and NOT as an absence; NOT_FOUND the
    reverse; every other kind must be read as NEITHER, so the consumer re-raises
    it loudly instead of swallowing it as a benign outcome. That third case is
    the one this whole module exists for — it is where an absent DATABASE and a
    missing INDEX live."""
    var pre = store_error_says_precondition(msg)
    var nf = store_error_says_not_found(msg)
    if kind == String(STORE_KIND_PRECONDITION):
        return pre and not nf
    if kind == String(STORE_KIND_NOT_FOUND):
        return nf and not pre
    return (not pre) and (not nf)


# -----------------------------------------------------------------------------
# §4 — Reading the generic (untyped) client error.
# -----------------------------------------------------------------------------


def firestore_http_status(err: String) -> Int:
    """The HTTP status in a `FirestoreClient` error, which carries the
    generated client's `(<verb> <method>: HTTP <n>, <CODE> (code <c>), ...)`,
    or -1 when the message carries none (the request got no answer).

    ⚠ Read from `: HTTP ` and NOT from the first run of digits: a resource
    path routinely contains digits (`api-service-us-central1`). Anchoring on
    the frame komira_gcp_core writes is the difference between a status and a
    coincidence."""
    var at = err.find(": HTTP ")
    if at < 0:
        return -1
    var bs = err.as_bytes()
    var i = at + 7
    var acc = 0
    var saw = False
    while i < len(bs):
        var c = Int(bs[i])
        if c < 48 or c > 57:
            break
        acc = acc * 10 + (c - 48)
        saw = True
        i += 1
    if not saw:
        return -1
    return acc


def _kind_for_http_status(status: Int) -> String:
    """The StoreError kind for an untyped HTTP status, matching the GCS gRPC
    mapper's arms one for one (401/403 -> PERMISSION_DENIED, 429/503 ->
    THROTTLED, 5xx -> TRANSPORT, other 4xx -> MALFORMED).

    ⚠ 429 and 503 are THROTTLED — RETRYABLE — while every other 4xx is
    MALFORMED. A permanent rejection classified as throttling makes a retry
    layer spin forever on a request that can never succeed."""
    if status == 401 or status == 403:
        return String(STORE_KIND_PERMISSION_DENIED)
    if status == 429 or status == 503:
        return String(STORE_KIND_THROTTLED)
    if status == 408 or status >= 500:
        return String(STORE_KIND_TRANSPORT)
    if status >= 400:
        return String(STORE_KIND_MALFORMED)
    # A 2xx/3xx here means the client raised for a reason that is not an HTTP
    # status at all (a parse failure, a transport dial error). TRANSPORT is the
    # honest class and matches the GCS mapper's no-recognizable-prefix arm.
    return String(STORE_KIND_TRANSPORT)


def firestore_store_error_kind(err: String) -> String:
    """The StoreError kind for a raised `FirestoreClient` error.

    ⛔ THE FIVE TYPED ARMS ARE PREFIX TESTS OVER PAIRWISE-DISJOINT PREFIXES, so
    this is a decision procedure and the order below is documentation, not
    semantics. That is the whole reason the typed sentinels are used instead of
    reading the HTTP status: `FirestoreDatabaseAbsent` and `FirestoreNotFound`
    are BOTH HTTP 404 with a NOT_FOUND status token, and the only thing that
    separates them is which sentinel the client already decided on.

    THE TWO THAT MATTER, and why neither is what it looks like:

      * DATABASE ABSENT -> MALFORMED, **not** NOT_FOUND. It is a permanent
        configuration fault affecting every request forever. As NOT_FOUND the
        registry would answer `found:false` for every service in the world and
        look healthy doing it.
      * DATABASE PRECONDITION (a missing composite index) -> MALFORMED, **not**
        PRECONDITION. It is permanent; as a CAS conflict the caller retries,
        fails identically, and reports contention that does not exist."""
    if is_already_exists_error(err):
        # create_if_absent lost: the document already exists. This IS the 412.
        return String(STORE_KIND_PRECONDITION)
    if is_precondition_failed_error(err):
        # update_if_unchanged lost: the document's updateTime moved. Also a 412.
        return String(STORE_KIND_PRECONDITION)
    if is_database_absent_error(err):
        return String(STORE_KIND_MALFORMED)
    if is_database_precondition_error(err):
        return String(STORE_KIND_MALFORMED)
    if is_not_found_error(err):
        return String(STORE_KIND_NOT_FOUND)
    return _kind_for_http_status(firestore_http_status(err))


# -----------------------------------------------------------------------------
# §5 — The projection.
# -----------------------------------------------------------------------------


def firestore_resource_uri(
    database: String, collection: String, doc: String
) -> String:
    """`firestore://<database>/<collection>/<doc>` — the analog of the GCS
    mapper's `gs://<bucket>/<key>`. A doc-less form (`<collection>/`) is used by
    the collection-scoped verbs."""
    var out = String("firestore://")
    out += database
    out += String("/")
    out += collection
    out += String("/")
    out += doc
    return out^


def map_firestore_error_to_store_error(
    op: String, resource_uri: String, err: String
) -> Error:
    """Re-project a raised `FirestoreClient` Error into the
    `StoreError[<KIND>] ... status=<http>` shape every `ConditionalWriteStore`
    consumer already understands.

    The output is composed in exactly two pieces:

      * a HEAD `StoreError[<KIND>] ` and a TAIL ` status=<http>`, both derived
        from the KIND and never from the input; and
      * a MIDDLE (op, resource, the client's error with Firestore's status) that
        is run through `defuse_classifier_tokens` first.

    and is then CHECKED with `message_class_is_exactly` before it is returned.
    If the check fails — which requires a token this module does not know about
    — the middle is discarded rather than emitted, because a message that reads
    as the wrong class is worse than a message with no detail in it."""
    var kind = firestore_store_error_kind(err)
    var http = store_kind_to_http(kind)

    var middle = String("")
    middle += op
    middle += String(" ")
    middle += resource_uri
    middle += String(" firestore_detail=")
    middle += err
    var was_defused = defusing_changed(middle)
    var safe_middle = defuse_classifier_tokens(middle)
    if was_defused:
        safe_middle += String(" note=classifier-tokens-defused")

    var msg = String("StoreError[")
    msg += kind
    msg += String("] ")
    msg += safe_middle
    msg += String(" status=")
    msg += String(http)
    if message_class_is_exactly(msg, kind):
        return Error(msg)

    # The defuser missed something. Emit the minimal form, which carries only
    # content this module generated and therefore cannot be misclassified.
    var minimal = String("StoreError[")
    minimal += kind
    minimal += String("] ")
    # The op is defused here TOO. It is a constant at every call site today, but
    # a caller-supplied one carrying `404` would reproduce the defect inside the
    # very branch that exists to prevent it.
    minimal += defuse_classifier_tokens(op)
    minimal += String(
        " (Firestore detail WITHHELD: it carried a StoreError classifier token"
        " this mapper could not defuse, and emitting it would have made this"
        " error read as a different class) status="
    )
    minimal += String(http)
    return Error(minimal)
