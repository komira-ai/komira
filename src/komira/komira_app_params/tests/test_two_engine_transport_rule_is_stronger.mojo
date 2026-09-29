# =============================================================================
# test_two_engine_transport_rule_is_stronger — ★ THE TEST OF A TEST.
#
#   The two-engine gate asserts a PER-NAME rule instead of a COUNT. Replacing a
#   gate with a "stronger" one is a claim, and a claim about a gate is exactly
#   the kind that gets asserted in a commit message and never measured. This
#   file MEASURES it.
# =============================================================================
#
# The requirement: prove the strengthening, do not claim it. Construct a bundle
# that PASSES the count rule and FAILS the per-name one. If none can be
# constructed, the per-name rule is NOT stronger.
#
# Both rules live in `komira_app_params.two_engine_transport` — the count is
# kept there for NO other purpose than this comparison (it has no other caller,
# and its docstring refuses one). Keeping it lets this file run BOTH over the
# SAME constructed state and report where they disagree, instead of comparing a
# live rule against a remembered one.
#
# ── ⚠ WHAT "STRONGER" MEANS HERE, STATED BEFORE IT IS MEASURED ──────────────
# NOT "a logical superset". It is not one, and rows (6)+(7) prove it is not: the
# per-name rule deliberately ADMITS a state the count refuses — an app whose
# engine-B render stamps a Secret Manager MOUNT while its non-secret values ride
# argv. That admission is the entire point, because the count makes that state
# unreachable and thereby blocks an app's non-secret values on account of
# secrets they have nothing to do with.
#
# The claim being measured is the one that matters for a GATE:
#
#   ★ ON THE FAILURE THE GATE EXISTS TO PREVENT — a revision shipped with its
#     required parameters absent, which `parse_app_params` refuses to start —
#     THE PER-NAME RULE REFUSES STATES THE COUNT ACCEPTS.
#
# Row (3) is that measurement and it is the load-bearing one: it constructs a
# bundle the count PASSES and the crash-loop's own definition REFUSES.
#
# ── THE FOUR ROWS THAT CARRY THE ARGUMENT ───────────────────────────────────
#   (1) the measuring stick is not a constant function — without this, "passes
#       the count" is a property of every input and proves nothing;
#   (2) COUNTEREXAMPLE A — a double-sourced value: count PASSES, new REFUSES;
#   (3) COUNTEREXAMPLE B — a required parameter nothing produces: count PASSES,
#       new REFUSES. ★ This is the crash-loop, and this counterexample rests on
#       NO change to the inputs — only on the rule's shape;
#   (6) the new rule is not trivially red, and (7) names the ONE state it newly
#       admits, so the loosening is written down rather than discovered.
#
# ⚠ (2) AND (3) DEPEND ON DIFFERENT THINGS, AND THE DIFFERENCE IS REPORTED. (3)
# is pure rule-shape: the same two numbers the count reads, a state it accepts, a
# defect it cannot see. (2) additionally needs the ARM-1 env set to be WIDER than
# the number the count reads — which it is whenever the count is taken over one
# env writer (say, a relay-settings writer) while engine B ALSO stamps other
# names (a deployment id, a key set, a datastore project) from its general
# deployment spec. The count is then blind to env names it claims to be
# counting. Row (2) is stated with that dependency named rather than folded into
# the result.
#
# HERMETIC. Pure in-process calls on constructed values. No bundle, no network, no
# cloud, no secret — `check_two_engine_transport` reads nothing and raises
# nothing, which is what lets this file drive it across states no checked-in
# bundle contains.
# =============================================================================

from std.testing import assert_true, assert_false, assert_equal

from komira_app_params import (
    TE_OK,
    TE_DOUBLE_SOURCED,
    TE_UNPRODUCED_REQUIRED,
    te_arm_label,
    EngineAParam,
    EngineBRow,
    check_two_engine_transport,
    retired_count_rule_passes,
)


comptime _APP: String = "example-app"


def _params(var items: List[EngineAParam]) -> List[EngineAParam]:
    return items^


def _verdict_label(arm: Int) -> String:
    return te_arm_label(arm)


# =============================================================================
# (1) THE MEASURING STICK DISCRIMINATES.
#
# Every counterexample below is of the form "the count PASSES this". If the count
# passed EVERYTHING, that observation would be free and the comparison worthless.
# So the retired rule is pinned to answer BOTH ways first.
# =============================================================================
def test_the_retired_count_rule_is_not_a_constant_function() raises:
    # The two states it ACCEPTS: fully migrated, and not migrated.
    assert_true(
        retired_count_rule_passes(5, 0),
        "the retired count rule refused `declared=5, env=0` (fully migrated),"
        " which is one of its two passing states. If this is False the function"
        " is not the count rule and every comparison below is against"
        " something else",
    )
    assert_true(
        retired_count_rule_passes(0, 6),
        "the retired count rule refused `declared=0, env=6` (not migrated) —"
        " the state of an app that has not started migrating, which the count"
        " must accept",
    )
    # The two states it REFUSES: half-migrated, and the vacuous both-empty.
    assert_false(
        retired_count_rule_passes(5, 6),
        "the retired count rule ACCEPTED `declared=5, env=6` (the half-cut). It"
        " is the state the rule existed to refuse; a stick that accepts it"
        " measures nothing",
    )
    assert_false(
        retired_count_rule_passes(0, 0),
        "the retired count rule ACCEPTED `declared=0, env=0` — both engines"
        " rendering nothing, which the count refuses outright as a probe that"
        " measured nothing rather than as agreement",
    )
    print("  test_the_retired_count_rule_is_not_a_constant_function: PASS")


# =============================================================================
# (2) ★ COUNTEREXAMPLE A — A DOUBLE-SOURCED VALUE.
#      The count PASSES it. ARM 1 REFUSES it.
#
# ⚠ THIS ONE DEPENDS ON THE WIDER ENV SET, AND THAT IS NAMED IN THE HEADER. A
# count taken over ONE env writer's output (say, relay settings) is legitimately
# ZERO for a customer org with no connected relay — the pre-connect state —
# while engine B's general deployment spec goes on stamping other names.
#
# So: the bundle declares `EXAMPLE_DEPLOYMENT_ID` as a parameter, engine B
# stamps an env var of that exact name, and the count — looking at the relay
# writer alone — sees `declared=1, env=0` and calls it a completed migration.
# =============================================================================
def test_a_double_sourced_value_passes_the_count_and_fails_arm_one() raises:
    var declared = List[EngineAParam]()
    declared.append(
        EngineAParam(
            String("EXAMPLE_DEPLOYMENT_ID"),
            String("app-deployment-id"),
            False,
        )
    )

    # What the RETIRED rule measured: the relay writer's count, which is 0 here.
    var count_env_seen = 0
    assert_true(
        retired_count_rule_passes(len(declared), count_env_seen),
        "PRECONDITION FAILED: this counterexample is only interesting if the"
        " COUNT accepts it. It did not, so it is not a counterexample and this"
        " row proves nothing about the strengthening",
    )

    # What engine B ACTUALLY stamps, which is what ARM 1 reads.
    var env_names = List[String]()
    env_names.append(String("EXAMPLE_DEPLOYMENT_ID"))
    env_names.append(String("EXAMPLE_JWKS"))

    var v = check_two_engine_transport(
        String(_APP), env_names, declared, List[EngineBRow]()
    )
    assert_false(
        v.ok(),
        "⛔ THE NEW RULE ACCEPTED A DOUBLE-SOURCED VALUE. The bundle declares a"
        " parameter named `EXAMPLE_DEPLOYMENT_ID` and engine B stamps an env"
        " var of that exact name onto the same binary. If this is accepted, ARM"
        " 1 is not implemented and the per-name rule is not stronger — it is"
        " merely different",
    )
    assert_equal(
        v.arm,
        TE_DOUBLE_SOURCED,
        String("refused, but for the WRONG REASON: expected DOUBLE_SOURCED, got")
        + String(" ")
        + _verdict_label(v.arm)
        + String(". A gate that goes red for an unrelated reason is a gate that")
        + String(" will go green when that reason is fixed"),
    )
    assert_equal(
        v.offender,
        String("EXAMPLE_DEPLOYMENT_ID"),
        "the verdict named the wrong env var",
    )
    print(
        "  test_a_double_sourced_value_passes_the_count_and_fails_arm_one: PASS"
        " (count ACCEPTS, new rule REFUSES with DOUBLE_SOURCED)"
    )


# =============================================================================
# (3) ★★ COUNTEREXAMPLE B — A REQUIRED PARAMETER NOTHING PRODUCES.
#       THE CRASH-LOOP ITSELF. The count PASSES it. ARM 2 REFUSES it.
#
# ★ THIS IS THE LOAD-BEARING ROW OF THE WHOLE FILE, and it rests on NOTHING but
# the shape of the two rules — same app, same two numbers, no widened input, no
# reinterpretation. The count's "fully migrated" passing state is `declared > 0
# AND env == 0`, and it accepts that state for ANY set of declared parameters,
# including one where every single parameter is REQUIRED and NOTHING produces it.
#
# That is exactly the failure the count exists to prevent — a revision shipped
# with its required parameters absent, which `parse_app_params` refuses to
# start — and the count cannot see it, because a required-and-unproduced
# parameter counts exactly the same as a satisfied one.
# =============================================================================
def test_a_required_unproduced_parameter_passes_the_count_and_fails_arm_two() raises:
    var declared = List[EngineAParam]()
    declared.append(
        EngineAParam(String("RELAY_VENDOR"), String("relay-vendor"), True)
    )
    declared.append(
        EngineAParam(String("RELAY_REGION"), String("relay-region"), True)
    )

    # ★ THE COUNT'S OWN NUMBERS, UNMODIFIED: two parameters declared, zero env
    # stamped. This is the count's "fully migrated" state and it accepts it.
    var env_names = List[String]()
    assert_true(
        retired_count_rule_passes(len(declared), len(env_names)),
        "PRECONDITION FAILED: the count must ACCEPT this state for it to be a"
        " counterexample. `declared=2, env=0` is its `fully migrated` arm",
    )

    # ⛔ AND NOTHING PRODUCES EITHER OF THEM. Engine B's parameter table has no
    # row for this app, so every per-customer deploy renders NEITHER flag.
    var produced = List[EngineBRow]()

    var v = check_two_engine_transport(
        String(_APP), env_names, declared, produced
    )
    assert_false(
        v.ok(),
        "⛔⛔ THE NEW RULE ACCEPTED A REVISION THAT CANNOT START. Two REQUIRED"
        " parameters are declared and engine B produces neither, so"
        " `parse_app_params` refuses the revision by name on every customer"
        " deploy. If this is accepted the per-name rule DROPPED the crash-loop"
        " protection instead of strengthening it, which is the one outcome the"
        " change was forbidden to have",
    )
    assert_equal(
        v.arm,
        TE_UNPRODUCED_REQUIRED,
        String("refused for the WRONG REASON: expected UNPRODUCED_REQUIRED, got")
        + String(" ")
        + _verdict_label(v.arm),
    )
    assert_equal(
        v.offender,
        String("relay-vendor"),
        "the verdict must name the FIRST unproduced required flag so an operator"
        " reading a stopped build is sent to one parameter, not to a set",
    )
    print(
        "  test_a_required_unproduced_parameter_passes_the_count_and_fails_arm_two:"
        " PASS (count ACCEPTS the crash-loop, new rule REFUSES it)"
    )


# =============================================================================
# (4) ARM 1's LEDGER BRIDGE — the HALF-EXECUTED migration.
#
# An engine-B row's `replaces_env` is the one non-guessing statement
# that env name E and flag F are the same value on two transports. A row that
# retires `EXAMPLE_LOCAL_DOMAINS` while the render still stamps it is the
# half-cut, and neither the count (`declared=1, env=1` -> it refuses, but for the
# undifferentiated reason "the numbers disagree") nor name-identity alone catches
# it: the parameter is named `LOCAL_DOMAINS`, not `EXAMPLE_LOCAL_DOMAINS`.
# =============================================================================
def test_the_ledger_bridge_catches_a_half_executed_migration() raises:
    var declared = List[EngineAParam]()
    declared.append(
        EngineAParam(String("LOCAL_DOMAINS"), String("local-domains"), False)
    )

    var produced = List[EngineBRow]()
    produced.append(
        EngineBRow(
            String("local-domains"), String("EXAMPLE_LOCAL_DOMAINS")
        )
    )

    var env_names = List[String]()
    env_names.append(String("EXAMPLE_LOCAL_DOMAINS"))

    var v = check_two_engine_transport(
        String(_APP), env_names, declared, produced
    )
    assert_false(
        v.ok(),
        "⛔ the ledger bridge did not fire: engine B's own row says"
        " `--local-domains` RETIRES `EXAMPLE_LOCAL_DOMAINS`, and the render"
        " is still stamping it. Name identity cannot catch this (`LOCAL_DOMAINS`"
        " != `EXAMPLE_LOCAL_DOMAINS`), so without the ledger arm ARM 1 is"
        " blind to every migrated value whose parameter name is not spelled like"
        " its env key — which is all of them",
    )
    assert_equal(v.arm, TE_DOUBLE_SOURCED, "wrong arm for the half-cut")

    # ── THE DISCRIMINATION. Same declaration, same row, env NO LONGER STAMPED:
    # the completed migration, which must be ACCEPTED. Without this half, the row
    # above is satisfied by an ARM 1 that refuses unconditionally.
    var done = check_two_engine_transport(
        String(_APP), List[String](), declared, produced
    )
    assert_true(
        done.ok(),
        String("⛔ the COMPLETED migration was REFUSED: ") + done.detail,
    )
    print("  test_the_ledger_bridge_catches_a_half_executed_migration: PASS")


# =============================================================================
# (5) NEITHER ARM FIRES ON A CONFORMING STATE — the anti-"always red" pin.
#
# A rule that returns a refusal for every input passes rows (2), (3) and (4)
# perfectly and gates nothing, because it can never distinguish a tree that
# conforms from one that does not.
# =============================================================================
def test_a_fully_conforming_migration_is_accepted() raises:
    var declared = List[EngineAParam]()
    declared.append(
        EngineAParam(String("RELAY_VENDOR"), String("relay-vendor"), True)
    )
    declared.append(
        EngineAParam(String("LOCAL_DOMAINS"), String("local-domains"), False)
    )

    var produced = List[EngineBRow]()
    produced.append(
        EngineBRow(
            String("relay-vendor"), String("EXAMPLE_RELAY_VENDOR")
        )
    )
    produced.append(
        EngineBRow(
            String("local-domains"), String("EXAMPLE_LOCAL_DOMAINS")
        )
    )

    var v = check_two_engine_transport(
        String(_APP), List[String](), declared, produced
    )
    assert_true(
        v.ok(),
        String(
            "⛔ a fully conforming migration was REFUSED — every declared"
            " parameter is produced by engine B and no env name is stamped at"
            " all. A rule that refuses this refuses everything: "
        )
        + v.detail,
    )
    assert_equal(v.arm, TE_OK, "expected TE_OK")
    print("  test_a_fully_conforming_migration_is_accepted: PASS")


# =============================================================================
# (6) ★ THE UNBLOCKING, MEASURED — AND IT IS THE ONE DIRECTION IN WHICH THE NEW
#      RULE ADMITS MORE THAN THE COUNT.
#
# Consider an app that stamps Secret Manager MOUNTS. A Cloud Run secret reaches
# a container exactly one way — a `secretKeyRef` ENV VAR — and a secret-typed
# parameter instead puts a resource NAME on argv for an in-process reader, which
# the app may not have. Then `pipeline env == 0` is unreachable for this app,
# and the count blocks its NON-SECRET values on account of secrets they have
# nothing to do with.
#
# The state below is that end-state: the non-secret value on argv, produced by
# engine B; the secret still a mount. The count REFUSES it (`declared=1, env=1`).
# The per-name rule ACCEPTS it — and it is right to, because no value is on two
# transports and nothing required is unproduced.
# =============================================================================
def test_a_secret_mount_beside_argv_params_is_admitted_and_the_count_refused_it() raises:
    var declared = List[EngineAParam]()
    declared.append(
        EngineAParam(String("RELAY_VENDOR"), String("relay-vendor"), True)
    )

    var produced = List[EngineBRow]()
    produced.append(
        EngineBRow(
            String("relay-vendor"), String("EXAMPLE_RELAY_VENDOR")
        )
    )

    # THE SECRET, STILL A MOUNT. It is not a parameter and never becomes one
    # while no in-process resolver exists.
    var env_names = List[String]()
    env_names.append(String("EXAMPLE_RELAY_TOKEN"))

    assert_false(
        retired_count_rule_passes(len(declared), len(env_names)),
        "PRECONDITION FAILED: this row's whole claim is that the COUNT refused"
        " this state. If the count accepts it, the count was not the blocker and"
        " the per-name rule had no unblocking to do",
    )

    var v = check_two_engine_transport(
        String(_APP), env_names, declared, produced
    )
    assert_true(
        v.ok(),
        String(
            "⛔ THE PER-NAME RULE DID NOT UNBLOCK ANYTHING. A secret env MOUNT"
            " sitting beside a produced argv parameter is the end-state an app"
            " with secrets has to be able to reach; if the new rule also refuses it, the"
            " migration is blocked for exactly the reason it was before: "
        )
        + v.detail,
    )
    print(
        "  test_a_secret_mount_beside_argv_params_is_admitted_and_the_count_refused_it:"
        " PASS (count REFUSES, new rule ACCEPTS — the one intended loosening)"
    )


# =============================================================================
# (7) ⚠ THE RESIDUAL, PINNED SO IT IS A DECISION AND NOT A DISCOVERY.
#
# ARM 1 has TWO exact bridges and NO fuzzy one. The consequence: an OPTIONAL
# parameter whose env twin engine B still stamps, with NO engine-B row tying the
# two, is caught by NEITHER arm. `LOCAL_DOMAINS` / `EXAMPLE_LOCAL_DOMAINS` is
# exactly that shape while engine B has no row for the app.
#
# It is ACCEPTED here, deliberately, and this row says so out loud:
#   * a third bridge would have to GUESS a parameter name from an env name, and a
#     guessing gate (a file-name hop, a source-text scan) is a gate with holes;
#   * the obligation is carried at the end of the wire that knows — the app's own
#     boot-time parameter check refuses to serve without it;
#   * and the moment engine B grows the row, the LEDGER bridge covers it — which
#     row (4) has just measured.
#
# ⚠ IF YOU CLOSE THIS RESIDUAL, THIS ROW GOES RED. That is intended: closing it is
# a change of contract and should require deleting a pin that explains itself,
# not a silent tightening.
# =============================================================================
def test_the_named_residual_is_accepted_and_written_down() raises:
    var declared = List[EngineAParam]()
    declared.append(
        EngineAParam(String("LOCAL_DOMAINS"), String("local-domains"), False)
    )

    var env_names = List[String]()
    env_names.append(String("EXAMPLE_LOCAL_DOMAINS"))

    var v = check_two_engine_transport(
        String(_APP), env_names, declared, List[EngineBRow]()
    )
    assert_true(
        v.ok(),
        String(
            "the NAMED RESIDUAL is no longer accepted. If you closed it on"
            " purpose, delete this row together with the residual paragraph in"
            " `two_engine_transport.mojo`'s header — both describe a hole that no"
            " longer exists. If you did not, ARM 1 has grown a bridge that"
            " matches more than exact identity, and that is the failure mode this"
            " row exists to make loud: "
        )
        + v.detail,
    )
    print(
        "  test_the_named_residual_is_accepted_and_written_down: PASS (accepted,"
        " and covered by the app's boot-time check + the ledger bridge once"
        " engine B grows the row)"
    )


def main() raises:
    test_the_retired_count_rule_is_not_a_constant_function()
    test_a_double_sourced_value_passes_the_count_and_fails_arm_one()
    test_a_required_unproduced_parameter_passes_the_count_and_fails_arm_two()
    test_the_ledger_bridge_catches_a_half_executed_migration()
    test_a_fully_conforming_migration_is_accepted()
    test_a_secret_mount_beside_argv_params_is_admitted_and_the_count_refused_it()
    test_the_named_residual_is_accepted_and_written_down()
    print(
        "OK test_two_engine_transport_rule_is_stronger — the per-name rule"
        " REFUSES two states the retired count ACCEPTED (a double-sourced value;"
        " a required parameter nothing produces — the crash-loop itself), is not"
        " trivially red, and admits exactly ONE state the count refused (a secret"
        " env MOUNT beside produced argv parameters), which is the state an app"
        " with secrets has to be able to reach"
    )
