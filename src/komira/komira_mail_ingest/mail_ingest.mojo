# =============================================================================
# komira_mail_ingest/mail_ingest.mojo — the PROVIDER-NEUTRAL inbound-mail
#   ingestion seam: what it means for a domain's mail to have somewhere to land.
# =============================================================================
#
# WHAT THIS IS. The provider-neutral abstraction over inbound mail; the one
#   implementation (AWS SES) lives elsewhere. This file names NO provider. It has
#   ZERO deps (the `komira_icalendar` leaf shape) precisely so the neutrality is a BUILD-GRAPH
#   FACT and not a claim in a comment: a package with no edges cannot reach an
#   AWS client, so nothing here can quietly grow one.
#
# WHY AN ABSTRACTION AT ALL, WHEN THERE IS ONE IMPLEMENTATION. Not to enable a
#   second cloud. It is because the three ways this path silently loses customer
#   mail are all PROVIDER-INDEPENDENT statements about routing tables, and a rule
#   that lives only in prose is not enforced:
#
#     ⛔ HAZARD 1 — THE ACCOUNT HAS EXACTLY ONE ACTIVE ROUTE TABLE.
#        A naive "ensure ours is active" DEACTIVATES whatever is live. If the
#        active table carries a different name than the one a client defaults
#        to, activating the default is an account-wide inbound outage that
#        reports no error. `plan_activation` makes that a REFUSAL.
#
#     ⛔ HAZARD 2 — A RECIPIENT IS AN EXACT WHOLE STRING. It is NOT a suffix and
#        NOT a domain tree. `example.com` and `inbound.example.com` cover neither
#        the other, so a domain served on both needs TWO separate rules.
#        `MailRecipient` is a parsed type whose
#        only comparison is whole-string equality, and `assert_table_covers`
#        names the missing recipient rather than reporting a domain covered.
#
#     ⛔ HAZARD 3 — RE-CREATING AN IDENTITY ROTATES ITS DKIM KEYS. Easy-DKIM
#        mints THREE fresh tokens on every identity creation, so any create /
#        recreate leaves the domain unverified until DNS is republished.
#        `dkim_republish_required` is the predicate a caller must consult before
#        it reports an onboarding successful.
#
#   A hazard that lives in prose is re-learned by whoever did not read the prose.
#   The point of this file is that all three now have a CALLER that cannot skip
#   them and a TEST that fails when they are weakened.
#
# WHAT THIS FILE IS NOT. It is not a transport, not a client, and not a resource
#   graph. It holds no credential, opens no socket, and performs no I/O: every
#   function here is a PURE decision over values a caller already read. That is
#   what makes the refusals testable with zero sockets and zero mocks.
#
# ── ENCAPSULATION ────────────────────────────────────────────────────────────
# Value-typed surface only; ZERO UnsafePointer anywhere; NO wildcard origin; NO
# unsafe_from_address; NO byte-slab. Flat-String / List value PODs throughout
# (no pointer fields, so no stale-pointer hazard across destroy and recreate).
# Mojo 1.0.0b2 (def-only).
# =============================================================================


# =============================================================================
# §0 — Comptime vocabulary.
# =============================================================================

# `plan_activation` verbs — what a caller may do about the account's ONE active
# inbound route table.
comptime ACTIVATION_NOOP: Int = 0
"""Our table is ALREADY the active one. Do nothing. (The steady state.)"""

comptime ACTIVATION_BOOTSTRAP: Int = 1
"""NO table is active at all — the empty account. Activating ours takes nothing
away from anyone, so it is the one case where activation is safe."""

# Identity verification states — the neutral read-back.
comptime IDENTITY_ABSENT: Int = 0
"""No identity exists for this domain."""

comptime IDENTITY_PENDING: Int = 1
"""The identity exists, its DNS records ARE published, and the provider is still
checking them. Mail is not yet accepted, but WAITING IS THE CORRECT ACTION.

⚠ THIS IS NARROWER THAN "not verified". "DNS has not been published" and "DNS
has not propagated yet" are TWO STATES THAT NEED OPPOSITE OPERATOR RESPONSES.
See `IDENTITY_DNS_UNPUBLISHED`."""

comptime IDENTITY_DNS_UNPUBLISHED: Int = 4
"""The identity exists and the provider has LOOKED UP its verification records
and found NOTHING. The customer has published no DNS.

★ WHY THIS IS A SEPARATE STATE — AND WHY THE ABSTRACTION WAS WRONG WITHOUT IT.
Waiting resolves `IDENTITY_PENDING`; waiting NEVER resolves this one. Fusing them
produces an onboarding flow that reports "verification in progress" for a domain
where nothing will happen until the customer acts — the most expensive sentence
a mail-onboarding UI can say, because it is indistinguishable from progress.

The distinction is PROVIDER-INDEPENDENT: any DNS-verified identity system can
tell "I queried and got NXDOMAIN" from "I queried, got an answer, still
checking". That is why it belongs here and not in the AWS conformer.

On AWS SES, for an identity with nothing published:
    DkimAttributes.Status      = PENDING          <- identical in both states
    VerificationStatus         = PENDING          <- identical in both states
    VerificationInfo.ErrorType = TYPE_NOT_FOUND   <- ONLY this separates them
`VerificationInfo` is ABSENT once verification succeeds, so an empty ErrorType on
a PENDING identity legitimately means "published, still checking"."""

comptime IDENTITY_VERIFIED: Int = 2
"""The identity is verified and DKIM is signing. The only state in which the
domain's mail actually arrives."""

comptime IDENTITY_FAILED: Int = 3
"""Verification was attempted and FAILED (a bad or missing record that the
provider has given up on). Distinct from PENDING: waiting longer will not fix
it — the records must be republished."""


def _fold_ascii_lower(s: String) -> String:
    """Lower-case an ASCII string. Domain names are case-INSENSITIVE (RFC 1035
    §2.3.3), so the recipient comparison folds case — and ONLY case. Nothing else
    is normalized: a trailing dot, a leading label, and any whitespace are all
    REFUSED at parse time rather than silently repaired, because a "helpful"
    normalization is how one recipient quietly becomes a different one."""
    var out = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c >= 65 and c <= 90:
            out += chr(Int(c) + 32)
        else:
            out += chr(Int(c))
    return out


# =============================================================================
# §1 — MailRecipient — an EXACT, whole-string inbound recipient (HAZARD 2).
#
# ★ THE WHOLE POINT OF THIS TYPE IS THAT IT HAS NO SUFFIX COMPARISON. There is
#   deliberately no `covers()`, no `matches_subdomain()`, no `parent()`. The only
#   question it answers is whole-string equality, because that is the only
#   question the provider answers. A type that offered a suffix test would let a
#   caller write the check that reads correct and loses mail.
# =============================================================================
@fieldwise_init
struct MailRecipient(Copyable, Movable, Deinitable):
    """One inbound recipient the provider matches EXACTLY and as a WHOLE STRING:
    either a bare domain (`example.com`) or a full address (`user@example.com`).

    ⛔ `example.com` DOES NOT COVER `inbound.example.com`, and the reverse is
    equally false. Each needs its own rule. This is not a quirk to work around —
    it is the provider's matching rule, and modelling it as anything else is how
    a domain gets reported covered while its mail is 550'd at RCPT.

    Construct with `parse` (which refuses the forms that would silently mis-
    match); compare with `equals`. Flat-String value POD (no pointer fields)."""

    var value: String
    """The parsed, case-folded recipient. Never empty (parse refuses)."""

    @staticmethod
    def parse(raw: String) raises -> MailRecipient:
        """Parse `raw` into an exact recipient, REFUSING every form that would
        silently mis-match. Case is folded (domains are case-insensitive);
        nothing else is repaired.

        Refused, each with the reason it loses mail:
          * EMPTY — an empty recipient in a rule means CATCH-ALL at some
            providers and "matches nothing" at others. Never write it by
            accident; a caller that wants a catch-all must say so with a type
            that can express it.
          * a `*` WILDCARD — there is no wildcard matching. `*.example.com` is
            matched literally, so it matches nothing at all and the rule looks
            present while receiving nothing.
          * a LEADING or TRAILING DOT — `.example.com` / `example.com.` are the
            two shapes a caller reaches for when it believes suffix matching
            exists. Both are literal strings that match no real recipient.
          * INTERNAL WHITESPACE — a recipient list is comma-joined on the wire;
            an embedded space is either a truncation or two recipients that will
            be sent as one and match neither."""
        var folded = _fold_ascii_lower(raw)
        if folded.byte_length() == 0:
            raise Error(
                "MailRecipient.parse: REFUSED an EMPTY recipient. An empty"
                " recipient is a CATCH-ALL at some providers and matches nothing"
                " at others — it must never be produced by accident. Name the"
                " exact domain or address this rule is for."
            )
        if String("*") in folded:
            raise Error(
                "MailRecipient.parse: REFUSED the wildcard recipient '"
                + folded
                + "'. Inbound recipient matching is EXACT and whole-string —"
                " there is no wildcard. A '*' is matched literally, so this rule"
                " would exist and receive NOTHING. Enumerate each recipient"
                " explicitly (a domain and its 'inbound.' subdomain are TWO"
                " recipients)."
            )
        var b = folded.as_bytes()
        if b[0] == 46:
            raise Error(
                "MailRecipient.parse: REFUSED the leading-dot recipient '"
                + folded
                + "'. A leading dot is the shape a caller writes when it believes"
                " SUFFIX matching exists. It does not: this would be matched as a"
                " literal string and receive nothing. Write the full recipient."
            )
        if b[len(b) - 1] == 46:
            raise Error(
                "MailRecipient.parse: REFUSED the trailing-dot recipient '"
                + folded
                + "'. The fully-qualified trailing dot is not part of the"
                " recipient string the provider compares against, so this would"
                " match nothing. Drop the trailing dot."
            )
        for i in range(len(b)):
            var c = b[i]
            if c == 32 or c == 9 or c == 10 or c == 13:
                raise Error(
                    "MailRecipient.parse: REFUSED the recipient '"
                    + folded
                    + "' because it contains WHITESPACE. Recipient lists are"
                    " comma-joined on the wire, so embedded whitespace is either"
                    " a truncation or two recipients fused into one that will"
                    " match neither."
                )
        return MailRecipient(folded)

    def equals(self, other: MailRecipient) -> Bool:
        """WHOLE-STRING equality — the ONLY comparison this type offers, and the
        only one the provider performs. Both sides are already case-folded by
        `parse`, so this is a plain string compare."""
        return self.value == other.value


def recipients_for_domain(domain: String, inbound_label: String) raises -> List[MailRecipient]:
    """The recipients a domain needs EXPLICIT rules for: the bare domain AND its
    `<inbound_label>.` subdomain — TWO recipients, because neither covers the
    other (HAZARD 2).

    ★ THIS FUNCTION EXISTS TO BE THE ANSWER TO A QUESTION CALLERS GET WRONG.
    A domain served at its apex and its inbound subdomain needs exactly this
    pair — two rules, two object-key prefixes — because a single rule does not
    receive the subdomain's mail. Returning a LIST rather than a single recipient
    is the point: a caller cannot accidentally handle only one.

    An empty `inbound_label` yields just the bare domain (the caller that
    genuinely serves only the apex)."""
    var out = List[MailRecipient]()
    out.append(MailRecipient.parse(domain))
    if inbound_label.byte_length() > 0:
        out.append(MailRecipient.parse(inbound_label + "." + domain))
    return out^


# =============================================================================
# §1b — THE ONE DERIVATION OF A ROUTE RULE'S NAME.
#
# ⛔⛔ THIS IS THE ONLY PLACE THE NAME IS BUILT. Two code-owned derivations for
#   the same resource that disagree on an input are a silent leak: a rule
#   CREATED under one spelling and DELETED under the other is not a failed
#   delete — it is a SUCCESSFUL delete of NOTHING (the provider answers "rule
#   does not exist", the caller reads that as already-gone), leaving the
#   accept-list entry live and the provider still receiving a departed
#   customer's mail. Every side — create, delete, the re-read that proves a
#   delete happened, and descriptors — calls `receipt_rule_name_for`.
#
# ★ WHY A VERBATIM CONCATENATION, AND NOT A CHARACTER-SUBSTITUTION FOLD
#   (e.g. '.' and '@' folded to '-').
#
#   1. A FOLD IS LOSSY, AND THE LOSS IS A COLLISION IN A SHARED NAMESPACE.
#      '.' -> '-' maps `a.b` and `a-b` onto ONE name. There is exactly ONE active
#      rule table per account holding EVERY tenant's rules, and create is
#      idempotent-by-ADOPTION — so a collision there is one tenant silently
#      adopting another tenant's rule. Concatenation is injective.
#
#   2. THE PREFIX MAKES OUR RULES RECOGNISABLE. A bare, unprefixed name is
#      indistinguishable from a rule somebody added by hand in the same table,
#      so nothing could safely delete it.
#
#   3. THE NAME IS AN ADDRESS. Callers persist it (as `<rule_set>|<rule_name>`)
#      so a reaper can find the rule later. Changing the derivation RENAMES every
#      rule already created, orphaning both the persisted row and the rule it
#      names. The derivation is therefore pinned by a golden test.
#
# ⚠ '@' IS NOT FOLDED. A rule name may not contain one, and `MailRecipient`
#   accepts an ADDRESS (`user@example.com`) as well as a domain. Rather than fold
#   it — the lossy move above — that shape is REFUSED, at the mutation
#   sites, by `assert_receipt_rule_name_legal`. Per-address rules need an encoding
#   chosen on purpose, not a character substitution.
#
# ⚠ TWO FUNCTIONS, ONE DERIVATION. `receipt_rule_name_for` is TOTAL and PURE so
#   that a descriptor, a log line and a matcher can spell the name without a
#   `raises` in their signature — the ripple that would otherwise reach four
#   non-raising callers. The legality REFUSAL is separate and belongs at the
#   CREATE/DELETE sites, which are already raising. It is not a second
#   derivation: it builds no name, it judges one.
# =============================================================================
comptime DEFAULT_RECEIPT_RULE_PREFIX: String = "komira-inbound-"
"""The prefix used when a caller names none. Every rule this library derives
carries a prefix; it is what separates OUR accept-list entries from the
hand-made ones sharing the account's single active table — a bare, unprefixed
name is indistinguishable from a rule somebody added in the console, so nothing
could safely delete it.

The prefix is a PARAMETER of the derivation, so two deployments can share one
account's table under distinct namespaces. ⚠ Create, delete and the re-read must
be given the SAME prefix: a rule created under one prefix and deleted under
another is the silent no-op delete this section exists to prevent. A caller that
persists the derived name (`<rule_set>|<rule_name>`) addresses the rule by that
stored name, not by re-deriving it."""

comptime RECEIPT_RULE_NAME_MAX_BYTES: Int = 64
"""The provider's own ceiling on a rule name. SES `ReceiptRule.Name`: at most 64
characters, ASCII letters/digits/`_`/`-`/`.`, starting and ending alphanumeric.
Checked HERE so an over-long domain is a refusal naming the domain, rather than a
provider-side validation error surfacing at create time with no mention of it."""


def _is_ascii_alnum(c: Int) -> Bool:
    return (
        (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57)
    )


def _is_rule_name_byte(c: Int) -> Bool:
    """ASCII letters, digits, '_', '-', '.' — the SES rule-name charset."""
    return _is_ascii_alnum(c) or c == 45 or c == 46 or c == 95


def receipt_rule_name_for(
    recipient: String, prefix: String = DEFAULT_RECEIPT_RULE_PREFIX
) -> String:
    """THE name of the provider rule that accepts `recipient` — `prefix`
    (default `komira-inbound-`) prepended verbatim.

    ★ ONE DERIVATION, CALLED BY EVERY SIDE — create, delete, the re-read that
    proves a delete happened, and the descriptors that name the resource for an
    operator. Nothing re-spells the concatenation; see this section's header for
    what a second spelling costs.

    TOTAL AND PURE ON PURPOSE — it never raises, so a non-raising descriptor or
    matcher can call it. Whether the result is a name the provider will ACCEPT
    (prefix and recipient both) is a separate question, asked by
    `assert_receipt_rule_name_legal` at the sites that mutate."""
    return prefix + recipient


def assert_receipt_rule_prefix_legal(prefix: String) raises:
    """REFUSE a prefix that cannot begin a legal rule name: empty, not starting
    with a letter or digit, holding a byte outside the rule-name charset, or so
    long that no recipient byte fits under `RECEIPT_RULE_NAME_MAX_BYTES`.

    An empty prefix is refused because the prefix is what makes our rules
    recognisable among hand-made ones; see `DEFAULT_RECEIPT_RULE_PREFIX`."""
    var n = prefix.byte_length()
    if n == 0:
        raise Error(
            "assert_receipt_rule_prefix_legal: REFUSED an EMPTY prefix. Without"
            " one, our rules are indistinguishable from rules added by hand in"
            " the same table, so none of them could safely be deleted."
        )
    var b = prefix.as_bytes()
    if not _is_ascii_alnum(Int(b[0])):
        raise Error(
            "assert_receipt_rule_prefix_legal: REFUSED the prefix '"
            + prefix
            + "' because it does not START with a letter or digit. The prefix"
            " is the start of every rule name, and a rule name must start"
            " alphanumeric."
        )
    for i in range(n):
        var c = Int(b[i])
        if not _is_rule_name_byte(c):
            raise Error(
                "assert_receipt_rule_prefix_legal: REFUSED the prefix '"
                + prefix
                + "' — byte "
                + String(c)
                + " at offset "
                + String(i)
                + " is outside the rule-name charset (ASCII letters, digits,"
                " '_', '-', '.')."
            )
    if n >= RECEIPT_RULE_NAME_MAX_BYTES:
        raise Error(
            "assert_receipt_rule_prefix_legal: REFUSED the prefix '"
            + prefix
            + "' — it is "
            + String(n)
            + " bytes, leaving no room for a recipient under the provider's "
            + String(RECEIPT_RULE_NAME_MAX_BYTES)
            + "-byte ceiling on a rule name."
        )


def assert_receipt_rule_name_legal(
    recipient: String, prefix: String = DEFAULT_RECEIPT_RULE_PREFIX
) raises:
    """REFUSE, before a rule is CREATED, a prefix or recipient whose derived
    name the provider will not accept — naming the byte and the reason. The
    prefix is judged first, by `assert_receipt_rule_prefix_legal`.

    ⛔ IT REFUSES RATHER THAN REPAIRS, AND THAT IS THE WHOLE POINT. Every repair
    available here is a character substitution, and a substitution is what maps
    two distinct recipients onto ONE name in the ONE table that holds every
    tenant's rules. A refusal costs an onboarding attempt; a collision costs
    somebody else's mail.

    ⚠ THE **DELETE** PATH DELIBERATELY DOES NOT CALL THIS, AND THAT ASYMMETRY IS
    NOT AN OVERSIGHT. A create decides what will exist; a delete addresses what
    ALREADY does. If this predicate ever tightens, every rule minted under the
    older, looser reading must still be REACHABLE — a teardown that refuses to
    derive the name of a rule it created is a rule that can never be removed,
    which is the leak a single derivation exists to close."""
    assert_receipt_rule_prefix_legal(prefix)
    if recipient.byte_length() == 0:
        raise Error(
            "assert_receipt_rule_name_legal: REFUSED an EMPTY recipient. The"
            " derived name would be the bare prefix `"
            + prefix
            + "`, which is a rule for nobody and which EVERY domain's teardown"
            " would then try to delete. Name the exact domain this rule is for."
        )
    var b = recipient.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if _is_rule_name_byte(c):
            continue
        if c == 64:
            raise Error(
                "assert_receipt_rule_name_legal: REFUSED the ADDRESS-shaped"
                " recipient '"
                + recipient
                + "'. A receipt-rule name may not contain '@', and folding it"
                " into '-' would map"
                " `user@example.com` and the real domain `user-example.com` onto"
                " ONE name, in the ONE table that holds every tenant's rules,"
                " where create ADOPTS an existing rule silently. Per-address"
                " rules need an encoding chosen on purpose; until one exists,"
                " give the rule a DOMAIN recipient."
            )
        raise Error(
            "assert_receipt_rule_name_legal: REFUSED the recipient '"
            + recipient
            + "' — byte "
            + String(c)
            + " at offset "
            + String(i)
            + " is outside the rule-name charset (ASCII letters, digits, '_',"
            " '-', '.'). The provider rejects the create, and it does so far from"
            " here; refusing at the mint is what makes the reason readable."
        )
    if not _is_ascii_alnum(Int(b[len(b) - 1])):
        raise Error(
            "assert_receipt_rule_name_legal: REFUSED the recipient '"
            + recipient
            + "' because it does not END in a letter or digit. A rule name must"
            " start AND end alphanumeric; the prefix guarantees the start, the"
            " recipient decides the end. A trailing '.' or '-' is a malformed"
            " domain in any case."
        )
    var derived = receipt_rule_name_for(recipient, prefix)
    if derived.byte_length() > RECEIPT_RULE_NAME_MAX_BYTES:
        raise Error(
            "assert_receipt_rule_name_legal: REFUSED '"
            + recipient
            + "' — the derived rule name is "
            + String(derived.byte_length())
            + " bytes and the provider's ceiling is "
            + String(RECEIPT_RULE_NAME_MAX_BYTES)
            + ". A truncation here would produce a name that is a PREFIX of"
            " another domain's, so the ceiling is a refusal rather than a"
            " shortening."
        )


# =============================================================================
# §2 — MailDropTarget / MailIngestRoute / MailRouteTable — the neutral routing
#      table: which recipients are accepted, and where their bytes land.
# =============================================================================
@fieldwise_init
struct MailDropTarget(Copyable, Movable, Deinitable):
    """Where an accepted message's raw bytes are written: an object-store
    `container` (an S3 bucket / a GCS bucket) plus the `key_prefix` under which
    this recipient's objects are grouped. Provider-neutral — no ARN, no URL.

    The prefix is per-recipient by design: it is what lets an object-expiry rule
    stay prefix-FREE (a prefix set that grows with every customer is a lifecycle
    rule that silently stops covering new ones)."""

    var container: String
    var key_prefix: String


@fieldwise_init
struct MailIngestRoute(Copyable, Movable, Deinitable):
    """One accepted recipient and the disposition of its mail: drop the bytes at
    `drop`, and announce the arrival on `notify_channel`.

    ⚠ `notify_channel` IS NOT OPTIONAL IN PRACTICE. The stored message body does
    NOT contain the SMTP envelope — the recipient list the provider actually
    observed — so a route with no notification channel produces objects nobody
    can attribute to a recipient. `assert_route_deliverable` refuses it."""

    var recipient: MailRecipient
    var drop: MailDropTarget
    var notify_channel: String
    var enabled: Bool
    """⛔ A DISABLED ROUTE CONTRIBUTES NOTHING. The provider rejects at RCPT
    exactly as if the route did not exist, so coverage checks MUST ignore it —
    counting a disabled route as coverage reports a domain live while nothing can
    be delivered to it."""


@fieldwise_init
struct MailRouteTable(Copyable, Movable, Deinitable):
    """The account's inbound routing table: a NAME, whether it is the ACTIVE one,
    and its routes.

    ⛔ THE ACCOUNT HAS EXACTLY ONE ACTIVE TABLE (HAZARD 1). A table that exists
    but is not active receives NOTHING, silently — and creating the table and its
    routes looks exactly like success. `active` is therefore a first-class field
    here rather than something a caller remembers to check."""

    var name: String
    var active: Bool
    var routes: List[MailIngestRoute]

    def enabled_recipients(self) -> List[MailRecipient]:
        """The recipients this table actually receives for — ENABLED routes only
        (a disabled route is inert). The list a coverage check reads."""
        var out = List[MailRecipient]()
        for i in range(len(self.routes)):
            if self.routes[i].enabled:
                out.append(self.routes[i].recipient.copy())
        return out^

    def receives_for(self, recipient: MailRecipient) -> Bool:
        """True iff an ENABLED route in this table receives for EXACTLY
        `recipient`. Whole-string — see `MailRecipient`."""
        for i in range(len(self.routes)):
            if self.routes[i].enabled and self.routes[i].recipient.equals(
                recipient
            ):
                return True
        return False


def assert_route_deliverable(route: MailIngestRoute) raises:
    """REFUSE a route that cannot actually deliver. Two ways a route is accepted
    by the provider and still loses the message:

      1. NO NOTIFY CHANNEL — the stored bytes do not carry the SMTP envelope, so
         without a notification carrying the observed recipient list the object
         is unattributable and the message is unroutable.
      2. NO DROP CONTAINER — a route with nowhere to write is accepted at RCPT
         and then discards the body."""
    if route.notify_channel.byte_length() == 0:
        raise Error(
            "assert_route_deliverable: REFUSED the route for '"
            + route.recipient.value
            + "' because it names NO notify channel. The stored message body does"
            " NOT contain the SMTP envelope — the recipient list the provider"
            " observed — so without a notification the dropped object cannot be"
            " attributed to a recipient and every message becomes unroutable."
        )
    if route.drop.container.byte_length() == 0:
        raise Error(
            "assert_route_deliverable: REFUSED the route for '"
            + route.recipient.value
            + "' because it names NO drop container. The route would be accepted"
            " at RCPT and then discard the body."
        )


def assert_table_covers(
    table: MailRouteTable, required: List[MailRecipient]
) raises:
    """REFUSE unless `table` has an ENABLED route for EVERY recipient in
    `required`, matched WHOLE-STRING (HAZARD 2).

    ★ THE ERROR NAMES THE MISSING RECIPIENT AND THE ONES THAT ARE PRESENT. A
    coverage failure whose message is "not covered" sends the reader to re-derive
    the table by hand; the interesting case is a table that holds the parent and
    not the subdomain, and that is only obvious when both lists are printed."""
    for i in range(len(required)):
        if not table.receives_for(required[i]):
            var have = String("")
            var live = table.enabled_recipients()
            for j in range(len(live)):
                if j > 0:
                    have += ", "
                have += live[j].value
            if len(live) == 0:
                have = String("<none>")
            raise Error(
                "assert_table_covers: the route table '"
                + table.name
                + "' has NO enabled route for the recipient '"
                + required[i].value
                + "'. Recipient matching is EXACT and WHOLE-STRING: a rule for a"
                " parent domain does NOT cover its subdomain, and a subdomain"
                " rule does not cover the parent — each needs its own route."
                " Enabled recipients present: "
                + have
            )


# =============================================================================
# §3 — plan_activation — HAZARD 1, as a REFUSAL rather than a comment.
# =============================================================================
def plan_activation(
    live_active_name: String,
    live_active_route_count: Int,
    desired_name: String,
) raises -> Int:
    """Decide what may be done about the account's ONE active inbound route
    table. Returns `ACTIVATION_NOOP` (ours is already active) or
    `ACTIVATION_BOOTSTRAP` (nothing is active — safe to activate). RAISES in
    every other case.

    ⛔ THE REFUSAL IS THE ENTIRE VALUE OF THIS FUNCTION. The account permits
    exactly ONE active inbound route table, so "activate ours" is not an additive
    operation — it DEACTIVATES whatever is live, instantly and silently, for
    every recipient that table served. If the live table's name differs from the
    name a client defaults to, activating the default takes inbound down for
    every customer at once, and nothing reports an error.

    The bootstrap case is the ONLY safe activation: when no table is active,
    activating ours takes nothing away from anyone. Note it is gated on the NAME
    being empty, not on the route count — an active table with zero routes still
    belongs to someone, and displacing it is still displacing it."""
    if desired_name.byte_length() == 0:
        raise Error(
            "plan_activation: REFUSED — the desired route-table name is EMPTY."
            " An empty name cannot be compared against the live active table, so"
            " proceeding would mean activating an unnamed table over whatever is"
            " currently serving inbound mail."
        )
    if live_active_name.byte_length() == 0:
        return ACTIVATION_BOOTSTRAP
    if live_active_name == desired_name:
        return ACTIVATION_NOOP
    raise Error(
        "plan_activation: REFUSED to activate the route table '"
        + desired_name
        + "' because a DIFFERENT table is already active: '"
        + live_active_name
        + "' (carrying "
        + String(live_active_route_count)
        + " route(s)). The account permits exactly ONE active inbound route"
        " table, so this activation would SILENTLY DEACTIVATE '"
        + live_active_name
        + "' and stop inbound mail for every recipient it serves — with no error"
        " reported anywhere. If '"
        + desired_name
        + "' is genuinely the table this deployment should own, adopt the live"
        " name instead of displacing it; if the live table is stale, retire it"
        " deliberately and separately."
    )


# =============================================================================
# §4 — MailIdentity + the DKIM republish predicate (HAZARD 3).
# =============================================================================
@fieldwise_init
struct DkimRecord(Copyable, Movable, Deinitable):
    """One DNS record a domain must publish for its mail identity to verify. The
    neutral shape — `name`/`kind`/`value` — is exactly what the `DnsProvider`
    seam applies, so an identity's records can be handed to any registrar
    conformer without a provider-shaped translation step."""

    var name: String
    var kind: String
    var value: String

    def equals(self, other: DkimRecord) -> Bool:
        """Whole-value equality across all three fields — the comparison the
        rotation predicate is built on."""
        return (
            self.name == other.name
            and self.kind == other.kind
            and self.value == other.value
        )


@fieldwise_init
struct MailIdentity(Copyable, Movable, Deinitable):
    """A domain's inbound/outbound mail identity: its verification `state`, and
    the DNS records that must be live for that state to become VERIFIED."""

    var domain: String
    var state: Int
    var records: List[DkimRecord]

    def is_verified(self) -> Bool:
        """True iff the identity is VERIFIED — the ONLY state in which mail for
        this domain actually arrives."""
        return self.state == IDENTITY_VERIFIED

    def waiting_will_help(self) -> Bool:
        """True iff the identity is progressing on its own and the caller should
        simply poll again. ⛔ FALSE for `IDENTITY_DNS_UNPUBLISHED` — the whole
        reason that state exists. An onboarding loop that polls a domain whose
        records were never published waits forever and reports progress."""
        return self.state == IDENTITY_PENDING

    def needs_dns_action(self) -> Bool:
        """True iff nothing will advance this identity until DNS is (re)published
        — either the customer never published (`IDENTITY_DNS_UNPUBLISHED`) or the
        provider gave up on what it found (`IDENTITY_FAILED`). This is the
        predicate an onboarding UI must branch on before it says "in progress"."""
        return (
            self.state == IDENTITY_DNS_UNPUBLISHED
            or self.state == IDENTITY_FAILED
        )

    @staticmethod
    def absent(domain: String) -> MailIdentity:
        """The no-identity-exists reading. Records are empty — an absent identity
        has no tokens, which is exactly why creating one rotates them."""
        return MailIdentity(domain, IDENTITY_ABSENT, List[DkimRecord]())


def dkim_republish_required(
    before: MailIdentity, after: MailIdentity
) raises -> Bool:
    """True iff the DNS records changed between two readings of the same
    domain's identity — i.e. the caller MUST republish DNS before reporting
    success (HAZARD 3).

    ⛔ EASY-DKIM MINTS FRESH TOKENS ON EVERY IDENTITY CREATION. A delete +
    recreate — including one done to "reset" a stuck identity — destroys the key
    pair and issues three NEW tokens, so the previously-published records now
    verify nothing and the domain is unverified until DNS is republished. The
    identity API reports the create as a success; nothing surfaces the rotation.
    So the rotation must be DERIVED, by comparing the records, which is what this
    does.

    Returns True when the record SET differs in any way (count, name, kind, or
    value). Order-insensitive: providers do not promise token order, and treating
    a reorder as a rotation would make every read demand a needless republish.

    RAISES if the two readings are for different domains — that is a caller bug
    (comparing two domains' identities), and answering it would be meaningless in
    either direction."""
    if before.domain != after.domain:
        raise Error(
            "dkim_republish_required: REFUSED to compare identities for DIFFERENT"
            " domains ('"
            + before.domain
            + "' vs '"
            + after.domain
            + "'). A rotation is a statement about ONE domain's records over"
            " time; comparing two domains answers nothing in either direction."
        )
    if len(before.records) != len(after.records):
        return True
    for i in range(len(after.records)):
        var found = False
        for j in range(len(before.records)):
            if after.records[i].equals(before.records[j]):
                found = True
                break
        if not found:
            return True
    return False


# =============================================================================
# §5 — MailIngestProvider — the seam. ONE implementation today (AWS SES); the
#      trait exists so the hazards above have a surface that cannot skip them.
# =============================================================================
trait MailIngestProvider(Movable, Deinitable):
    """The provider-neutral inbound-mail ingestion seam: read and converge a
    domain's identity, and read and converge the account's inbound route table.

    THE READ VERBS ARE THE ONLY SOURCE OF ACTUAL STATE (the `komira_iac`
    `Resource` discipline, for the same reason): a cached "we created it" flag
    cannot see a rule someone disabled, a table someone displaced, or an identity
    whose tokens rotated — which are precisely the three ways this path fails.

    ⛔ `activate_route_table` IS A SEPARATE VERB FROM `ensure_route_table`, AND
    THAT SEPARATION IS DELIBERATE. A table that exists but is not active receives
    nothing, silently, and creating the table and its routes looks exactly like
    success. A conformer MUST route its activation decision through
    `plan_activation` — the refusal is not optional politeness, it is what stops
    a deploy from taking every other customer's inbound mail down.

    Credentials are threaded PER-CALL as an opaque token (never a field — the
    custody rule): the caller owns the credential's lifetime, and a token parked
    on a long-lived conformer is the pool-lifecycle hazard this shape prevents.

    ENCAPSULATION: value-typed in/out only; ZERO UnsafePointer crosses the
    boundary; `raises` for a genuine backend fault (never for a routine
    absence — an absent identity is `IDENTITY_ABSENT`, not an error)."""

    def read_identity(mut self, domain: String, token: String) raises -> MailIdentity:
        """Read the LIVE identity for `domain`. An absent identity is
        `MailIdentity.absent(domain)` — NOT a raise. Raises only on a genuine
        backend fault (an authorization failure must NOT be laundered into
        'absent': that would report a domain unprovisioned and provoke a
        recreate, which rotates its DKIM tokens)."""
        ...

    def ensure_identity(mut self, domain: String, token: String) raises -> MailIdentity:
        """Create the identity for `domain` if absent; adopt it if present.
        Returns the identity AS READ BACK, so the caller can compare its records
        against a prior reading via `dkim_republish_required`.

        ⛔ IDEMPOTENT-BY-ADOPTION, NEVER BY RECREATE. An existing identity must be
        adopted untouched — deleting and recreating it to "start clean" destroys
        the DKIM key pair and unverifies the domain."""
        ...

    def read_active_route_table(mut self, token: String) raises -> MailRouteTable:
        """Read the account's ONE currently-ACTIVE inbound route table. When no
        table is active, returns a table with an EMPTY name and no routes — the
        bootstrap reading `plan_activation` treats as safe to activate. Raises
        only on a genuine backend fault."""
        ...

    def ensure_route(
        mut self, table_name: String, route: MailIngestRoute, token: String
    ) raises:
        """Create-or-adopt `route` in the table `table_name`. Idempotent. The
        conformer MUST have validated the route with `assert_route_deliverable`
        first — a route with no notify channel is accepted by the provider and
        then loses every message."""
        ...

    def remove_route(
        mut self, table_name: String, recipient: MailRecipient, token: String
    ) raises:
        """Remove the route for EXACTLY `recipient` from `table_name`. Idempotent
        — an already-absent route is a no-op, not an error."""
        ...

    def activate_route_table(mut self, table_name: String, token: String) raises:
        """Make `table_name` the account's ONE active inbound route table.

        ⛔ THE CALLER MUST HAVE CONSULTED `plan_activation` FIRST. This verb is
        unconditional by construction — the provider offers no compare-and-swap —
        so the only thing standing between a deploy and an account-wide inbound
        outage is that decision. A conformer that calls this without it can
        displace a live table and silently stop all inbound mail."""
        ...
