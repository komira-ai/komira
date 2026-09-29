# =============================================================================
# tests/test_receipt_rule_name_one_derivation.mojo — the falsifiers for THE ONE
#   derivation of a route rule's name.
# =============================================================================
#
# WHAT THIS IS EVIDENCE ABOUT. A route rule's name must be derived in exactly
# ONE place. Two derivations for the SAME resource that disagree — say a prefixed
# concatenation and a '.'/'@'-to-'-' fold:
#
#         "komira-inbound-" + d                 -> komira-inbound-acme.dev
#         d with '.' and '@' folded to '-'      -> acme-dev
#
# — both writing into the SAME account-global rule set, mean a rule created under
# one spelling and deleted under the other is not a failed delete: it is a
# SUCCESSFUL delete of NOTHING, reported as success, with the accept-list entry
# still live and SES still receiving a departed customer's mail.
#
# ⛔ THE ADDRESS-STABILITY ASSERTION IS THE MOST IMPORTANT ONE HERE.
# `test_the_rule_name_is_pinned` pins the derived name for a domain against its
# exact golden string. A rule's name is its address: changing the derivation
# RENAMES every rule already created — creating a new rule and orphaning the
# old — and this test makes that a RED rather than a discovery in a bill.
#
# ⚠ THE COLLISION TEST IS NOT DECORATION. `test_a_substitution_fold_is_not_
# injective` derives the fold INSIDE the test and shows two DIFFERENT recipients
# collapsing onto ONE name under it while staying distinct under the
# concatenation. It is the reason for the concatenation, stated as an executable
# fact rather than an opinion in a comment.
#
# PURE — no socket, no credential, no mock. Every function under test is a
# decision over values, so these run on the farm with nothing host-bound.
# =============================================================================

from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_not_equal,
)

from komira_mail_ingest.mail_ingest import (
    MailRecipient,
    RECEIPT_RULE_NAME_PREFIX,
    RECEIPT_RULE_NAME_MAX_BYTES,
    receipt_rule_name_for,
    assert_receipt_rule_name_legal,
)


# A domain and the exact rule name the derivation must produce for it.
comptime _DOMAIN: String = "example.com"
comptime _RULE_NAME: String = "komira-inbound-example.com"

# 60 'a' + ".dev" = 64 bytes, so the DERIVED name is 64 + 15 = 79 — over the
# provider's 64-byte ceiling. Written out rather than looped so the fixture's
# length is readable at the point it is used.
comptime _OVERLONG_DOMAIN: String = (
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.dev"
)


def _substitution_fold(recipient: String) -> String:
    """A character-substitution fold ('.' and '@' to '-'), derived here so its
    defect is executable.

    ⚠ THIS IS DELIBERATELY DEAD CODE UNDER TEST. It must never be a second
    derivation in the library; it lives here, in a test, so the reason the
    library does not fold is a checked fact."""
    var out = String("")
    var b = recipient.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == 46 or c == 64:  # '.' or '@'
            out += "-"
        else:
            out += chr(Int(c))
    return out


def test_the_rule_name_is_pinned() raises:
    """⛔ THE ADDRESS OF AN EXISTING RESOURCE MUST NOT MOVE.

    FAILS IF THE DERIVATION CHANGES SPELLING: the fold derives `example-com` for
    this domain, so switching to it would leave an existing
    `komira-inbound-example.com` rule addressed by nothing — a create of a second
    rule and an orphan of the first."""
    assert_equal(
        receipt_rule_name_for(String(_DOMAIN)),
        String(_RULE_NAME),
        "the derived rule name must match its pinned golden string",
    )
    assert_not_equal(
        _substitution_fold(String(_DOMAIN)),
        String(_RULE_NAME),
        "the substitution fold does NOT derive the pinned name",
    )
    print("  test_the_rule_name_is_pinned: PASS")


def test_one_derivation_serves_the_recipient_type_too() raises:
    """A conformer holding a `MailRecipient` calls THIS function with that
    recipient's value. Same function, both sides — which is the entire property,
    since a create and a delete that reach two different functions are a delete
    of nothing."""
    var r = MailRecipient.parse(String(_DOMAIN))
    assert_equal(
        receipt_rule_name_for(r.value),
        receipt_rule_name_for(String(_DOMAIN)),
        "the recipient-shaped call and the domain-shaped call are one function",
    )
    print("  test_one_derivation_serves_the_recipient_type_too: PASS")


def test_a_substitution_fold_is_not_injective() raises:
    """★ WHY A CONCATENATION. The fold maps `a.b` and `a-b` onto ONE name.
    There is exactly ONE active rule table per account, holding EVERY tenant's
    rules, and create is idempotent-by-ADOPTION — so a collision there is one
    tenant silently adopting another tenant's rule."""
    var a = String("acme.dev")
    var b = String("acme-dev")
    assert_equal(
        _substitution_fold(a),
        _substitution_fold(b),
        "two DIFFERENT domains collapse onto one name under the fold",
    )
    assert_not_equal(
        receipt_rule_name_for(a),
        receipt_rule_name_for(b),
        "the concatenation keeps them distinct",
    )
    print("  test_a_substitution_fold_is_not_injective: PASS")


def test_every_name_carries_the_prefix() raises:
    """The prefix is what separates OUR accept-list entries from the hand-made
    ones sharing the account's single table (e.g. hand-made `example-com` and
    `inbound-example-com`). The fold produces a BARE name, indistinguishable from
    something added in the console — so nothing could safely delete it."""
    assert_true(
        receipt_rule_name_for(String("acme.dev")).startswith(
            String(RECEIPT_RULE_NAME_PREFIX)
        ),
        "a derived rule name must be recognisably ours",
    )
    assert_false(
        _substitution_fold(String("acme.dev")).startswith(
            String(RECEIPT_RULE_NAME_PREFIX)
        ),
        "the fold produces an UNPREFIXED name",
    )
    print("  test_every_name_carries_the_prefix: PASS")


def test_an_address_shaped_recipient_is_refused_not_folded() raises:
    """⛔ '@' IS REFUSED, NOT FOLDED — and refusing is the point. `MailRecipient` accepts `user@example.com`; a rule name may not
    contain '@'. Substituting it is what makes `user@example.com` and the real
    domain `user.example.com` ONE address."""
    var raised = False
    var msg = String("")
    try:
        assert_receipt_rule_name_legal(String("user@example.com"))
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "an address-shaped recipient must be REFUSED")
    assert_true(
        String("@") in msg,
        "the refusal must name the character that cannot be encoded",
    )
    # And the fold's answer for the two colliding inputs, so the reason the
    # substitution was rejected is executable rather than asserted in prose.
    assert_equal(
        _substitution_fold(String("user@example.com")),
        _substitution_fold(String("user.example.com")),
        "the fold mapped an ADDRESS and a DOMAIN onto one name",
    )
    print("  test_an_address_shaped_recipient_is_refused_not_folded: PASS")


def test_an_empty_recipient_is_refused() raises:
    """The bare prefix is a rule for nobody, and EVERY domain's teardown would
    then derive it and try to delete it."""
    var raised = False
    try:
        assert_receipt_rule_name_legal(String(""))
    except:
        raised = True
    assert_true(raised, "an empty recipient must be REFUSED")
    print("  test_an_empty_recipient_is_refused: PASS")


def test_a_name_over_the_provider_ceiling_is_refused() raises:
    """A truncation would produce a name that is a PREFIX of another domain's, so
    the ceiling is a refusal rather than a shortening. The refusal must state the
    ceiling — a bare 'too long' sends the reader back to the provider's docs."""
    assert_true(
        receipt_rule_name_for(String(_OVERLONG_DOMAIN)).byte_length()
        > RECEIPT_RULE_NAME_MAX_BYTES,
        "the fixture must actually exceed the ceiling",
    )
    var raised = False
    var msg = String("")
    try:
        assert_receipt_rule_name_legal(String(_OVERLONG_DOMAIN))
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "an over-long derived name must be REFUSED")
    assert_true(
        String("64") in msg, "the refusal must name the provider's ceiling"
    )
    print("  test_a_name_over_the_provider_ceiling_is_refused: PASS")


def test_a_legal_domain_is_not_refused() raises:
    """★ WITHOUT THIS, EVERY REFUSAL TEST ABOVE IS MET BY A FUNCTION THAT ALWAYS
    RAISES. A domain, its inbound subdomain, and an underscore-bearing name must
    all pass."""
    assert_receipt_rule_name_legal(String(_DOMAIN))
    assert_receipt_rule_name_legal(String("inbound.example.com"))
    assert_receipt_rule_name_legal(String("acme_test.dev"))
    print("  test_a_legal_domain_is_not_refused: PASS")


def test_a_trailing_non_alphanumeric_is_refused() raises:
    """A rule name must start AND end alphanumeric. The prefix guarantees the
    start; the recipient decides the end."""
    var raised = False
    try:
        assert_receipt_rule_name_legal(String("acme.dev-"))
    except:
        raised = True
    assert_true(raised, "a trailing '-' must be REFUSED")
    print("  test_a_trailing_non_alphanumeric_is_refused: PASS")


def main() raises:
    print("test_receipt_rule_name_one_derivation:")
    test_the_rule_name_is_pinned()
    test_one_derivation_serves_the_recipient_type_too()
    test_a_substitution_fold_is_not_injective()
    test_every_name_carries_the_prefix()
    test_an_address_shaped_recipient_is_refused_not_folded()
    test_an_empty_recipient_is_refused()
    test_a_name_over_the_provider_ceiling_is_refused()
    test_a_legal_domain_is_not_refused()
    test_a_trailing_non_alphanumeric_is_refused()
    print("test_receipt_rule_name_one_derivation: ALL PASS")
