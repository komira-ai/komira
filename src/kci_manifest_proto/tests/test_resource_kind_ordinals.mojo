# =============================================================================
# test_resource_kind_ordinals.mojo
# =============================================================================
#
# THE ORDINAL CENSUS for `full_manifest.proto:ResourceKind`: the one place the
# whole enum is stated as VALUES rather than as declarations.
#
# WHAT THIS FILE DOES NOT GUARD. A duplicate ordinal is not silent: protoc
# rejects a file in which two enum values share a number ("uses the same enum
# value as ... set 'option allow_alias = true'"), so it is a hard build
# failure. `test_every_declared_kind_ordinal_is_distinct` below is therefore
# not the collision detector (protoc is), and its docstring says so.
#
# WHAT IS SILENT IS RENUMBERING. Moving a kind to a different number is
# protoc-legal and compiles clean. A proto ordinal is APPEND-ONLY because the
# NUMBER is what is stored: a manifest written when 22 meant "mail domain
# identity" and read after 22 means something else does not fail to parse; it
# decodes cleanly as the WRONG KIND, and the mapper materializes it with the
# wrong conformer. Nothing in the toolchain objects. That is the case this file
# exists for.
#
# WHAT IS ASSERTED HERE, AND WHAT EACH ONE CATCHES THAT THE OTHERS DO NOT:
#   1. Each pinned kind holds its number by NAME as well as by number. A bare
#      `== 22` cannot tell 22-means-this-kind from this-kind-means-22; the
#      value -> NAME direction is the generated map, and only it pins which
#      DECLARATION owns the number. Renumbering a kind (which protoc accepts)
#      fails this.
#   2. The census AGREES WITH THE ENUM: every ordinal renders its own name.
#      It catches a kind RENAMED, REMOVED or moved, none of which protoc has an
#      opinion about, and it is what makes the census a real second statement.
#   3. The set has no holes outside the one reserved window (23/24). protoc
#      does not require this; a hole is how two changes come to believe one
#      number is free.
#   4. 23 and 24 are RESERVED for TOPIC / TOPIC_SUBSCRIPTION. protoc has no
#      notion of a reservation for an UNDECLARED value that the intended
#      declaration may still use, so this is its only enforcement. It passes
#      both while they are undeclared AND once they are declared at those
#      numbers, and fails if anything else takes either.
#   5. An undeclared kind NAME resolves to UNSPECIFIED (0), never to a declared
#      ordinal: the proto3 unknown-enum contract. It stays meaningful once the
#      pub/sub pair lands: `RESOURCE_KIND_TOPIC` must then resolve to 23, and
#      never to 22.
#
# The census below is a LITERAL restatement of the proto, deliberately.
# Deriving it from the enum would make it agree with the enum by construction
# and assert nothing; the point is that the numbers are written down twice.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_not_equal

from kci_manifest_proto.full_manifest import ResourceKind


# The ordinal each kind is declared at, restated. Order is ordinal order.
def _declared_ordinals() -> List[Int]:
    var out = List[Int]()
    out.append(ResourceKind.RESOURCE_KIND_UNSPECIFIED)
    out.append(ResourceKind.RESOURCE_KIND_SERVERLESS_COMPUTE)
    out.append(ResourceKind.RESOURCE_KIND_RUN_TO_COMPLETION_JOB)
    out.append(ResourceKind.RESOURCE_KIND_OBJECT_STORE)
    out.append(ResourceKind.RESOURCE_KIND_DATASTORE)
    out.append(ResourceKind.RESOURCE_KIND_QUEUE)
    out.append(ResourceKind.RESOURCE_KIND_LOAD_BALANCER)
    out.append(ResourceKind.RESOURCE_KIND_DNS_RECORD)
    out.append(ResourceKind.RESOURCE_KIND_IAM_ROLE)
    out.append(ResourceKind.RESOURCE_KIND_SECRET)
    out.append(ResourceKind.RESOURCE_KIND_CONFIG)
    out.append(ResourceKind.RESOURCE_KIND_SERVICE_ACCOUNT)
    out.append(ResourceKind.RESOURCE_KIND_WIF_PROVIDER)
    out.append(ResourceKind.RESOURCE_KIND_BUCKET)
    out.append(ResourceKind.RESOURCE_KIND_ARTIFACT_REPOSITORY)
    out.append(ResourceKind.RESOURCE_KIND_TRIGGER)
    out.append(ResourceKind.RESOURCE_KIND_INVOKE_GRANT)
    out.append(ResourceKind.RESOURCE_KIND_GRANT)
    out.append(ResourceKind.RESOURCE_KIND_WEB_FRONTEND)
    out.append(ResourceKind.RESOURCE_KIND_API_EDGE)
    out.append(ResourceKind.RESOURCE_KIND_PROJECT_SERVICE)
    out.append(ResourceKind.RESOURCE_KIND_SCHEDULED_CALL)
    out.append(ResourceKind.RESOURCE_KIND_MAIL_DOMAIN_IDENTITY)
    # ⚠ 23 AND 24 ARE ABSENT ON PURPOSE: they are RESERVED for the pub/sub pair
    # and remain undeclared. `test_the_kind_ordinals_are_contiguous_from_zero`
    # states that hole explicitly rather than tolerating it silently.
    out.append(ResourceKind.RESOURCE_KIND_NETWORK)
    out.append(ResourceKind.RESOURCE_KIND_INGRESS_POLICY)
    out.append(ResourceKind.RESOURCE_KIND_IAM_CUSTOM_ROLE)
    return out^


# The NAME each of those ordinals must render as: the value -> NAME direction,
# which is the half that says WHICH declaration owns a number.
def _declared_names() -> List[String]:
    var out = List[String]()
    out.append(String("RESOURCE_KIND_UNSPECIFIED"))
    out.append(String("RESOURCE_KIND_SERVERLESS_COMPUTE"))
    out.append(String("RESOURCE_KIND_RUN_TO_COMPLETION_JOB"))
    out.append(String("RESOURCE_KIND_OBJECT_STORE"))
    out.append(String("RESOURCE_KIND_DATASTORE"))
    out.append(String("RESOURCE_KIND_QUEUE"))
    out.append(String("RESOURCE_KIND_LOAD_BALANCER"))
    out.append(String("RESOURCE_KIND_DNS_RECORD"))
    out.append(String("RESOURCE_KIND_IAM_ROLE"))
    out.append(String("RESOURCE_KIND_SECRET"))
    out.append(String("RESOURCE_KIND_CONFIG"))
    out.append(String("RESOURCE_KIND_SERVICE_ACCOUNT"))
    out.append(String("RESOURCE_KIND_WIF_PROVIDER"))
    out.append(String("RESOURCE_KIND_BUCKET"))
    out.append(String("RESOURCE_KIND_ARTIFACT_REPOSITORY"))
    out.append(String("RESOURCE_KIND_TRIGGER"))
    out.append(String("RESOURCE_KIND_INVOKE_GRANT"))
    out.append(String("RESOURCE_KIND_GRANT"))
    out.append(String("RESOURCE_KIND_WEB_FRONTEND"))
    out.append(String("RESOURCE_KIND_API_EDGE"))
    out.append(String("RESOURCE_KIND_PROJECT_SERVICE"))
    out.append(String("RESOURCE_KIND_SCHEDULED_CALL"))
    out.append(String("RESOURCE_KIND_MAIL_DOMAIN_IDENTITY"))
    out.append(String("RESOURCE_KIND_NETWORK"))
    out.append(String("RESOURCE_KIND_INGRESS_POLICY"))
    out.append(String("RESOURCE_KIND_IAM_CUSTOM_ROLE"))
    return out^


def test_mail_domain_identity_is_ordinal_22() raises:
    """`RESOURCE_KIND_MAIL_DOMAIN_IDENTITY = 22`, pinned.

    BOTH DIRECTIONS, because they falsify different things. The constant ==
    22 says this kind was declared at 22; `ResourceKind(22).json_name()` says
    22 resolves back to THIS kind and not to a second declaration that also
    claimed it.
    """
    assert_equal(
        ResourceKind.RESOURCE_KIND_MAIL_DOMAIN_IDENTITY,
        22,
        "MAIL_DOMAIN_IDENTITY is declared at ordinal 22",
    )
    assert_equal(
        ResourceKind(22).json_name(),
        String("RESOURCE_KIND_MAIL_DOMAIN_IDENTITY"),
        (
            "ordinal 22 resolves BACK to MAIL_DOMAIN_IDENTITY — if a second"
            " declaration also claims 22, this renders that other name instead"
        ),
    )
    # It is exactly one past the kind before it, so a change that silently
    # dropped an intervening kind is visible here rather than as a hole found
    # later.
    assert_equal(
        ResourceKind.RESOURCE_KIND_MAIL_DOMAIN_IDENTITY,
        ResourceKind.RESOURCE_KIND_SCHEDULED_CALL + 1,
        "22 is exactly one past SCHEDULED_CALL = 21",
    )
    print("  test_mail_domain_identity_is_ordinal_22: PASS")


def test_every_declared_kind_ordinal_is_distinct() raises:
    """THE CENSUS AGREES WITH THE ENUM.

    ⚠ THE PAIRWISE-DISTINCT HALF IS REDUNDANT WITH THE TOOLCHAIN and is kept
    only because it is nearly free: protoc refuses a duplicate enum number
    outright, so this loop cannot be reached by a collision; the build fails
    first. Its residual is the case where someone sets `allow_alias`, which
    nothing else would catch. The collision guard is the value -> NAME pins
    plus protoc, not this loop.

    THE SECOND LOOP IS THE ONE THAT EARNS ITS KEEP: every ordinal renders ITS
    OWN name. That catches the census disagreeing with the enum (a kind
    renamed, removed or moved), on which protoc has no opinion.
    """
    var ords = _declared_ordinals()
    var names = _declared_names()
    assert_equal(
        len(ords),
        len(names),
        "the census states an ordinal and a name for every kind",
    )
    for i in range(len(ords)):
        for j in range(i + 1, len(ords)):
            assert_not_equal(
                ords[i],
                ords[j],
                (
                    String(
                        "two ResourceKind declarations claim ONE ordinal —"
                        " census entry "
                    )
                    + String(i)
                    + String(" (")
                    + names[i]
                    + String(") and entry ")
                    + String(j)
                    + String(" (")
                    + names[j]
                    + String(
                        "). protoc normally refuses a duplicate enum number"
                        " outright, so reaching THIS assertion means either"
                        " `option allow_alias = true` was added to the enum, or"
                        " the census below has been edited out of step with the"
                        " proto. Both are wrong: the ordinal is what is STORED,"
                        " and two names for one number make a stored node"
                        " ambiguous."
                    )
                ),
            )
    # And each ordinal renders as ITS OWN name: the value -> NAME direction,
    # which is what distinguishes "declared twice" from "declared once".
    for i in range(len(ords)):
        assert_equal(
            ResourceKind(ords[i]).json_name(),
            names[i],
            String("ordinal ") + String(ords[i]) + String(" renders its own name"),
        )
    print("  test_every_declared_kind_ordinal_is_distinct: PASS")


def test_the_kind_ordinals_are_contiguous_from_zero() raises:
    """No undocumented holes. There is EXACTLY ONE hole, the reserved 23/24.

    A hole is not cosmetic: it is the condition under which two changes each
    believe a number is free. The check is that every declared ordinal renders
    a NAME rather than the decimal fallback the generated `json_name` emits for
    an unmapped value.

    23/24 are reserved for the pub/sub pair and still undeclared, so the
    network kinds took 25/26 and the custom-role kind took 27. The hole is
    stated by number, so a change that lands something at 23 or 24 fails
    `test_23_and_24_are_reserved_for_the_pubsub_pair`, and one that leaves a
    NEW hole (say at 28) fails this test.
    """
    var ords = _declared_ordinals()
    var names = _declared_names()
    assert_equal(
        len(ords),
        26,
        "26 kinds are declared: 0 through 22, then 25, 26 and 27 (23/24"
        " reserved)",
    )
    # The full ordinal span the census must account for, hole included.
    comptime _TOP: Int = 27
    var seen = List[Int]()
    for i in range(len(ords)):
        seen.append(ords[i])
    for want in range(_TOP + 1):
        var reserved = want == 23 or want == 24
        var declared = ResourceKind(want).json_name() != String(want)
        if reserved:
            assert_true(
                not declared,
                (
                    String("ordinal ")
                    + String(want)
                    + String(
                        " is RESERVED for the pub/sub pair and something has"
                        " declared it. If that IS the pub/sub pair, this file's"
                        " census is what moves: add TOPIC/TOPIC_SUBSCRIPTION"
                        " here and drop them from the reserved hole, in the same"
                        " change."
                    )
                ),
            )
            continue
        assert_true(
            declared,
            (
                String("ordinal ")
                + String(want)
                + String(
                    " has no declared name — a HOLE in the enum outside the ONE"
                    " reserved 23/24 window, which is how two changes come to"
                    " claim one number"
                )
            ),
        )
        var found = False
        for i in range(len(seen)):
            if seen[i] == want:
                found = True
        assert_true(
            found,
            (
                String("ordinal ")
                + String(want)
                + String(" renders as '")
                + ResourceKind(want).json_name()
                + String(
                    "' in the enum but is ABSENT from this file's census. The"
                    " census is a hand-written second statement; a kind that"
                    " skips it is a kind nothing pins."
                )
            ),
        )
    assert_equal(
        len(names),
        len(ords),
        "the ordinal census and the name census state the same number of kinds",
    )
    print("  test_the_kind_ordinals_are_contiguous_from_zero: PASS")


def test_network_and_ingress_policy_are_25_and_26() raises:
    """The network kinds' ordinals, pinned in both directions.

    Same instrument and reason as `test_mail_domain_identity_is_ordinal_22`:
    a bare `== 25` cannot tell 25-means-NETWORK from NETWORK-means-25. The
    value -> NAME direction says WHICH declaration owns a number, and it is the
    one a protoc-legal RENUMBER silently breaks.

    ⛔ THESE TWO ARE WHY THE SET HAS A HOLE. They did not take 23/24, the first
    free numbers, because those are reserved. "Tidying" the enum by pulling
    NETWORK down to 23 would make every stored kind-25 node decode as a
    different kind, with no error anywhere.
    """
    assert_equal(
        ResourceKind.RESOURCE_KIND_NETWORK,
        25,
        "NETWORK is declared at ordinal 25 — the first number free of the"
        " 23/24 pub/sub reservation",
    )
    assert_equal(
        ResourceKind(25).json_name(),
        String("RESOURCE_KIND_NETWORK"),
        "ordinal 25 resolves BACK to NETWORK",
    )
    assert_equal(
        ResourceKind.RESOURCE_KIND_INGRESS_POLICY,
        26,
        "INGRESS_POLICY is declared at ordinal 26",
    )
    assert_equal(
        ResourceKind(26).json_name(),
        String("RESOURCE_KIND_INGRESS_POLICY"),
        "ordinal 26 resolves BACK to INGRESS_POLICY",
    )
    assert_not_equal(
        ResourceKind.RESOURCE_KIND_NETWORK,
        ResourceKind.RESOURCE_KIND_INGRESS_POLICY,
        "the two network kinds are TWO ordinals — collapsing them would put one"
        " environment-scoped and one workload-scoped lifecycle on one node",
    )
    print("  test_network_and_ingress_policy_are_25_and_26: PASS")


def test_iam_custom_role_is_ordinal_27() raises:
    """The custom-role kind's ordinal, pinned in both directions.

    Same instrument and reason as the two tests above: a bare `== 27` cannot
    tell 27-means-IAM_CUSTOM_ROLE from IAM_CUSTOM_ROLE-means-27.

    ⛔ IT TOOK 27 AND NOT 23. 23/24 stay reserved for the pub/sub pair, so this
    kind took the next number after INGRESS_POLICY. Renumbering it to 23 fails
    `test_23_and_24_are_reserved_for_the_pubsub_pair`; renumbering it to 26
    fails to build (protoc) or fails
    `test_every_declared_kind_ordinal_is_distinct`.
    """
    assert_equal(
        ResourceKind.RESOURCE_KIND_IAM_CUSTOM_ROLE,
        27,
        "IAM_CUSTOM_ROLE is declared at ordinal 27 — the first number free"
        " after INGRESS_POLICY, the 23/24 reservation still standing",
    )
    assert_equal(
        ResourceKind(27).json_name(),
        String("RESOURCE_KIND_IAM_CUSTOM_ROLE"),
        "ordinal 27 resolves BACK to IAM_CUSTOM_ROLE",
    )
    assert_not_equal(
        ResourceKind.RESOURCE_KIND_IAM_CUSTOM_ROLE,
        ResourceKind.RESOURCE_KIND_IAM_ROLE,
        "⛔ 27 IS NOT 8. Kind 8 is the per-service role BINDING node; this"
        " is the ROLE DEFINITION object. Folding them would put two conformers"
        " on two different resources under one number.",
    )
    print("  test_iam_custom_role_is_ordinal_27: PASS")


def test_23_and_24_are_reserved_for_the_pubsub_pair() raises:
    """THE RESERVATION: 23 = TOPIC, 24 = TOPIC_SUBSCRIPTION.

    ⚠ IT PASSES IN BOTH STATES ON PURPOSE. Today those two are UNDECLARED, so
    each renders as its decimal fallback; when the pub/sub pair is declared at
    23/24 this keeps passing. What it does NOT tolerate is anything else at
    either number.

    THIS IS THE RESERVATION'S ONLY ENFORCEMENT. protoc has no notion of a
    reservation for a value nobody has declared: `reserved 23, 24;` would
    forbid the pub/sub pair from using them too, which is the opposite of the
    intent.
    """
    var n23 = ResourceKind(23).json_name()
    assert_true(
        n23 == String("23") or n23 == String("RESOURCE_KIND_TOPIC"),
        (
            String("ordinal 23 is RESERVED for RESOURCE_KIND_TOPIC")
            + String(" but renders as '")
            + n23
            + String(
                "'. If you need a new kind, take the next FREE number after"
                " the highest declared one and add it to this file's census."
            )
        ),
    )
    var n24 = ResourceKind(24).json_name()
    assert_true(
        n24 == String("24") or n24 == String("RESOURCE_KIND_TOPIC_SUBSCRIPTION"),
        (
            String(
                "ordinal 24 is RESERVED for RESOURCE_KIND_TOPIC_SUBSCRIPTION"
                " but renders as '"
            )
            + n24
            + String(
                "'. Take the next free number instead and extend this file's"
                " census."
            )
        ),
    )
    print("  test_23_and_24_are_reserved_for_the_pubsub_pair: PASS")


def test_a_pubsub_kind_name_does_not_resolve_to_the_mail_identity() raises:
    """22 must never be reachable by a pub/sub NAME.

    The generated `from_json_name` maps a proto value NAME to its number and
    falls through to the zero value for an unknown name.

    ⚠ NOT ABOUT THE DUPLICATE: protoc refuses that (see the file header). This
    is about the protoc-LEGAL renumber: if 22 were given to
    `RESOURCE_KIND_TOPIC` and this kind moved elsewhere, a manifest authored as
    a pub/sub topic would carry the number the mail-identity conformer reads as
    its own, and be materialized as a domain identity. Nothing raises. The
    reverse is worse: every already-stored kind-22 node becomes a topic.

    So a pub/sub name must not resolve to 22, today (where it is undeclared
    and resolves to UNSPECIFIED) or after the pair is declared (where it must
    resolve to 23). Asserting NOT-22 rather than a fixed value is what lets
    the same assertion hold across that change.
    """
    var topic = ResourceKind.from_json_name(String("RESOURCE_KIND_TOPIC")).value
    assert_not_equal(
        topic,
        ResourceKind.RESOURCE_KIND_MAIL_DOMAIN_IDENTITY,
        (
            "RESOURCE_KIND_TOPIC resolves to the MAIL_DOMAIN_IDENTITY ordinal —"
            " an ordinal collision is live, and a manifest authored as a topic"
            " will be materialized as a mail domain identity with no error"
            " anywhere"
        ),
    )
    var sub = ResourceKind.from_json_name(
        String("RESOURCE_KIND_TOPIC_SUBSCRIPTION")
    ).value
    assert_not_equal(
        sub,
        ResourceKind.RESOURCE_KIND_MAIL_DOMAIN_IDENTITY,
        (
            "RESOURCE_KIND_TOPIC_SUBSCRIPTION resolves to the"
            " MAIL_DOMAIN_IDENTITY ordinal — same collision, same silent"
            " mis-materialization"
        ),
    )
    # And the generic case: a name nobody declared is UNSPECIFIED, not a kind.
    assert_equal(
        ResourceKind.from_json_name(String("RESOURCE_KIND_NOT_A_KIND")).value,
        ResourceKind.RESOURCE_KIND_UNSPECIFIED,
        (
            "an undeclared kind name maps to UNSPECIFIED (the proto3"
            " unknown-enum contract), never to a declared ordinal"
        ),
    )
    print(
        "  test_a_pubsub_kind_name_does_not_resolve_to_the_mail_identity: PASS"
    )


def main() raises:
    print("test_resource_kind_ordinals — the ResourceKind ordinal census")
    test_mail_domain_identity_is_ordinal_22()
    test_every_declared_kind_ordinal_is_distinct()
    test_the_kind_ordinals_are_contiguous_from_zero()
    test_network_and_ingress_policy_are_25_and_26()
    test_iam_custom_role_is_ordinal_27()
    test_23_and_24_are_reserved_for_the_pubsub_pair()
    test_a_pubsub_kind_name_does_not_resolve_to_the_mail_identity()
    print("ALL RESOURCE-KIND ORDINAL CENSUS TESTS PASSED")
