# =============================================================================
# komira_app_params/two_engine_transport.mojo — ★ ONE BINARY, TWO DEPLOY
#   ENGINES: A PER-NAME TRANSPORT RULE, NOT A COUNT.
# =============================================================================
#
# Some managed apps are deployed by TWO engines onto ONE binary:
#
#   ENGINE A — the checked-in komira_ci TEMPLATE (the app's deploy bundle ->
#              its declared parameters -> `resolve_parameter_args` -> argv).
#              The DECLARATION: what parameters this app takes.
#   ENGINE B — the per-customer PIPELINE render. The RESOLUTION: it stamps
#              container ENV, and — for a migrated app — its own parameter table
#              produces `APP_PARAM:` entries that it renders onto argv.
#
# There is ONE binary. The moment it parses a value from argv it stops reading
# that value's env name, so the two engines must agree about WHICH TRANSPORT
# CARRIES WHICH VALUE. A revision that disagrees does not serve WRONG — it does
# not serve AT ALL, because `parse_app_params` is fail-loud on a missing REQUIRED
# parameter.
#
# ── ⛔ WHY NOT A COUNT ───────────────────────────────────────────────────────
#
# The obvious gate is a COUNT:
#
#     (bundle parameters > 0)   ==   (pipeline env == 0)
#
# A count says nothing about WHICH NAMES, and that has two separate consequences.
#
#   ⛔ (1) IT IS UNSATISFIABLE FOR ANY APP WITH A SECRET. A deploy delivers a
#   Secret Manager secret to a container exactly ONE way: a `secretKeyRef` ENV
#   VAR. A secret-typed parameter instead puts a `projects/…/secrets/…` RESOURCE
#   NAME on argv and obliges the app to dereference it in-process, which needs an
#   in-process secret reader. Without one, an app that mounts even ONE secret can
#   never reach `pipeline env == 0`, and its NON-SECRET values are blocked along
#   with the secrets they have nothing to do with. `check_two_engine_transport`
#   admits that state — a secret env mount coexisting with argv parameters — and
#   that is the ONLY direction in which it admits more than the count does.
#
#   ⛔ (2) IT NEVER CHECKS THE THING IT EXISTS TO PREVENT. Read the count's two
#   PASSING states:
#
#       declared > 0 AND env == 0     "fully migrated"
#       declared == 0 AND env > 0     "not migrated"
#
#   In the FIRST state the rule accepts ANY set of declared parameters, including
#   REQUIRED ones that NOTHING PRODUCES. That is precisely the crash-loop the
#   count is meant to prevent — `parse_app_params` refuses to start the
#   revision — and the count is blind to it, because one required-and-unproduced
#   parameter counts exactly the same as one required-and-produced one. ARM 2
#   below is that missing check, and `test_two_engine_transport_rule_is_stronger`
#   row (3) constructs the state and measures both rules on it: the count PASSES,
#   this rule REFUSES.
#
# So this is not a weaker rule that lets more apps through. It checks the FAILURE
# (a required parameter with no producer) instead of a PROXY for it (a count of
# env vars), and the proxy is both too strict in one direction and vacuous in the
# other.
#
# ── ⚠ THE RESIDUAL, STATED RATHER THAN HIDDEN ───────────────────────────────
# ARM 1 relates an env NAME to a declared PARAMETER through TWO EXACT bridges
# (name identity, and the `replaces_env` retirement ledger). It has NO fuzzy
# bridge, deliberately — a gate that matches fuzzily (a file-name hop, a
# source-text scan) is a gate with holes.
#
# The consequence is a NAMED residual: an OPTIONAL parameter whose env twin engine
# B still stamps, where NO engine-B row ties the two, is caught by NEITHER arm. It
# is not silently uncovered: the obligation is enforced at the end of the wire
# that knows, by the app's own boot-time parameter check, and the moment engine B
# grows the row the LEDGER bridge covers it. Closing it here would require a third
# bridge that guesses a param name from an env name, and a guessing gate is how a
# gate reports green.
#
# ZERO deps beyond `std`, like everything else in this package: the rule is
# consumed by bundle gates and must not drag a dependency closure into them (a
# package does not inline its transitive code, so every dep becomes the
# consumer's dep too).
#
# Mojo 1.0.0b2 (def-only, `comptime`).
# =============================================================================


# =============================================================================
# §1 — THE VERDICT ARMS.
#
# The verdict names WHICH arm fired, not merely that something did, so a test can
# assert a state is refused FOR THE RIGHT REASON. A gate whose test only checks
# "it went red" is satisfied by a rule that is red unconditionally.
# =============================================================================

comptime TE_OK: Int = 0
"""The two engines agree: no value is double-sourced, no required parameter is
unproduced."""

comptime TE_DOUBLE_SOURCED: Int = 1
"""ARM 1 — a value arrives on BOTH transports. Engine B stamps an env name that
the bundle also declares as a parameter."""

comptime TE_UNPRODUCED_REQUIRED: Int = 2
"""ARM 2 — the bundle declares a REQUIRED parameter that engine B produces no row
for. THIS IS THE CRASH-LOOP: engine B renders no flag, `parse_app_params` is
fail-loud, and the revision does not start."""


def te_arm_label(arm: Int) -> StaticString:
    """The arm's name, for a refusal message."""
    if arm == TE_OK:
        return "OK"
    if arm == TE_DOUBLE_SOURCED:
        return "DOUBLE_SOURCED"
    if arm == TE_UNPRODUCED_REQUIRED:
        return "UNPRODUCED_REQUIRED"
    return "UNKNOWN"


# =============================================================================
# §2 — THE TWO ENGINES' RECORDS, AS THIS RULE NEEDS THEM.
#
# ⚠ PRIMITIVE ON PURPOSE. The rule takes Strings and Bools, never either
# engine's own record type, so this leaf keeps its zero-dep closure AND so the
# falsifier can construct a state that no checked-in bundle contains. A rule that
# can only be driven by the real corpus can only be tested on states that already
# exist, which is the wrong half of the space.
# =============================================================================


struct EngineAParam(Copyable, Movable, Deinitable):
    """ONE parameter the bundle (engine A) declares."""

    var name: String
    """The parameter's name — the UPPER_SNAKE id the control plane carries opaquely
    and an operator types on `--param NAME=VALUE`. ⚠ It is NOT an env key, but it
    is drawn from the SAME UPPER_SNAKE namespace as one, which is what makes the
    name-identity bridge in ARM 1 an exact comparison rather than a guess."""

    var flag: String
    """The RESOLVED argv long flag WITHOUT `--`. ⚠ RESOLVED, never the authored
    `flag:` field: a parameter that omits it relies on the
    `name.lower().replace('_','-')` derivation, and a caller reading the raw field
    would report a parameter absent while the deploy renders it. Callers pass
    `param_flag_for(prm)`."""

    var required: Bool
    """Whether the parameter is required — an unresolved value REFUSES THE DEPLOY. ARM 2 is
    a claim about exactly these."""

    def __init__(out self, name: String, flag: String, required: Bool):
        self.name = name.copy()
        self.flag = flag.copy()
        self.required = required


struct EngineBRow(Copyable, Movable, Deinitable):
    """ONE parameter engine B produces, as this rule needs it — the two fields of
    engine B's parameter row that say what it renders and what it retires."""

    var flag: String
    """The kebab flag engine B renders on argv."""

    var replaces_env: String
    """The env NAME this parameter retires, or
    EMPTY for a parameter that never had an env form. ★ THIS IS THE LEDGER BRIDGE:
    it is the ONE authoritative, non-guessing statement that env name
    E and flag F are the SAME VALUE on two transports."""

    def __init__(out self, flag: String, replaces_env: String):
        self.flag = flag.copy()
        self.replaces_env = replaces_env.copy()


struct TwoEngineVerdict(Copyable, Movable, Deinitable):
    """What the rule found."""

    var arm: Int
    """`TE_*`."""

    var offender: String
    """The env name (ARM 1) or the flag (ARM 2) that fired it. EMPTY when OK."""

    var detail: String
    """The full refusal, written for someone reading a stopped build."""

    def __init__(out self, arm: Int, offender: String, detail: String):
        self.arm = arm
        self.offender = offender.copy()
        self.detail = detail.copy()

    def ok(self) -> Bool:
        return self.arm == TE_OK


def _has(items: List[String], want: String) -> Bool:
    for i in range(len(items)):
        if items[i] == want:
            return True
    return False


def _join(items: List[String]) -> String:
    var out = String("")
    for i in range(len(items)):
        if i > 0:
            out += String(", ")
        out += items[i].copy()
    if out.byte_length() == 0:
        return String("<none>")
    return out^


def _declared_flags(declared: List[EngineAParam]) -> List[String]:
    var out = List[String]()
    for i in range(len(declared)):
        out.append(declared[i].flag.copy())
    return out^


def _produced_flags(produced: List[EngineBRow]) -> List[String]:
    var out = List[String]()
    for i in range(len(produced)):
        out.append(produced[i].flag.copy())
    return out^


# =============================================================================
# §3 — ★ THE RULE.
# =============================================================================


def check_two_engine_transport(
    app_id: String,
    env_names: List[String],
    declared: List[EngineAParam],
    produced: List[EngineBRow],
) -> TwoEngineVerdict:
    """★ THE PER-NAME TWO-ENGINE RULE (see the module header for why not a
    count).

    `env_names` — the env var NAMES engine B stamps on this app's container.
    `declared`  — what the bundle (engine A) declares, flags already RESOLVED.
    `produced`  — engine B's parameter rows for `app_id`, as `EngineBRow`s.

    ARM 1 runs before ARM 2 so that a state which violates both is reported as the
    double-source, which is the one a reader can act on without knowing the
    migration's target state.

    ⚠ THIS FUNCTION IS TOTAL AND SIDE-EFFECT-FREE. It reads nothing, dials
    nothing, and raises nothing — every refusal is a returned verdict — so the
    falsifier can drive it across states no checked-in bundle contains."""

    # ── ARM 1 — NO DOUBLE-SOURCE. A value is EITHER a parameter OR an env var. ──
    # If the binary reads a value from argv it has stopped reading its env name;
    # if it reads the env name it is not reading argv. Both being present means
    # one of the two engines is feeding a channel the binary no longer listens to,
    # and WHICH one is not decidable from here — so the state is refused rather
    # than resolved.
    for e in range(len(env_names)):
        ref env_name = env_names[e]

        # BRIDGE (a) — NAME IDENTITY. A parameter name is UPPER_SNAKE, the same
        # namespace an env key is drawn from, so a bundle that declares
        # `name: "EXAMPLE_LOCAL_DOMAINS"` has named the very variable engine B
        # stamps. Exact string equality; no derivation, nothing to guess wrong.
        for i in range(len(declared)):
            if declared[i].name == env_name:
                return TwoEngineVerdict(
                    TE_DOUBLE_SOURCED,
                    env_name,
                    String("⛔ `")
                    + app_id
                    + String(
                        "` DOUBLE-SOURCES A VALUE. The bundle declares a"
                        " parameter named `"
                    )
                    + declared[i].name
                    + String("` (rendered as `--")
                    + declared[i].flag
                    + String(
                        "` on argv) while the per-customer pipeline render STILL"
                        " STAMPS an env var of that exact name onto the SAME"
                        " binary.\n\nThere is one binary and it reads a value"
                        " from ONE transport. Whichever engine it has stopped"
                        " listening to is now shipping configuration into a"
                        " channel with no reader — a value that looks"
                        " configured and is not.\n\nRemove the env stamp (engine"
                        " B should carry this value as an `APP_PARAM:` entry,"
                        " which it already renders onto argv) or drop the"
                        " parameter. Not both."
                    ),
                )

        # BRIDGE (b) — THE RETIREMENT LEDGER. An engine-B row's `replaces_env` is the
        # one authoritative statement that env name E and flag F carry the SAME
        # VALUE. A row that retires E, whose flag the bundle declares, while E is
        # STILL STAMPED, is a half-executed migration: the ledger says the value
        # moved to argv and the render did not follow.
        for r in range(len(produced)):
            if produced[r].replaces_env != env_name:
                continue
            for i in range(len(declared)):
                if declared[i].flag != produced[r].flag:
                    continue
                return TwoEngineVerdict(
                    TE_DOUBLE_SOURCED,
                    env_name,
                    String("⛔ `")
                    + app_id
                    + String("` DOUBLE-SOURCES A VALUE. `--")
                    + produced[r].flag
                    + String("` is declared by the bundle AND produced by engine")
                    + String(" B, whose own row records that it RETIRES the env")
                    + String(" var `")
                    + env_name
                    + String(
                        "` — and the render is STILL STAMPING that env var onto"
                        " the same container.\n\nThe migration is half-executed:"
                        " engine B's parameter table says the value moved to argv,"
                        " the env writer did not follow. Stop stamping `"
                    )
                    + env_name
                    + String(
                        "` (the row names it as retired for this app), or delete"
                        " the engine-B row. The two must move together."
                    ),
                )

    # ── ARM 2 — NO UNPRODUCED REQUIREMENT. ★ THIS IS THE CRASH-LOOP CHECK. ──────
    # `parse_app_params` refuses to start a revision that was not supplied a
    # REQUIRED parameter. Engine B renders argv from its own parameter table alone —
    # it does NOT read the bundle — so a required parameter with no engine-B row
    # is a flag that will never be rendered on the pipeline path, and every
    # customer deploy of this app fails to serve.
    #
    # ⚠ THE COUNT RULE DOES NOT CHECK THIS AT ALL. Its "fully
    # migrated" passing state (`declared > 0 AND env == 0`) is satisfied by a
    # bundle whose every parameter is required and unproduced.
    var b_flags = _produced_flags(produced)
    for i in range(len(declared)):
        if not declared[i].required:
            continue
        if _has(b_flags, declared[i].flag):
            continue
        return TwoEngineVerdict(
            TE_UNPRODUCED_REQUIRED,
            declared[i].flag,
            String("⛔⛔ `")
            + app_id
            + String("` DECLARES A REQUIRED PARAMETER NOTHING PRODUCES. `--")
            + declared[i].flag
            + String("` (parameter `")
            + declared[i].name
            + String(
                "`) is REQUIRED by the bundle, and engine B's parameter table"
                " produces no row for it.\n\nEngine B renders argv from its OWN table — it"
                " does not read the bundle — so on every per-customer deploy this"
                " flag is absent, `parse_app_params` refuses it by name, and the"
                " revision DOES NOT SERVE AT ALL. It does not serve wrong; it"
                " crash-loops.\n\nEngine B produces: "
            )
            + _join(b_flags)
            + String(
                "\n\nEither add the row to engine B's parameter table (with a"
                " source that actually resolves — a row added ahead of its"
                " source converts every deploy from 'works, on env' into"
                " 'refuses'), or make the parameter OPTIONAL and enforce the"
                " obligation at the end of the wire that knows: the app's own"
                " boot-time parameter check."
            ),
        )

    return TwoEngineVerdict(TE_OK, String(""), String(""))


# =============================================================================
# §4 — THE COUNT RULE, KEPT AS A MEASURING STICK AND NOTHING ELSE.
# =============================================================================


def retired_count_rule_passes(declared_count: Int, env_count: Int) -> Bool:
    """The count rule that `check_two_engine_transport` is measured against.

    It reads:

        (declared_count > 0)   ==   (env_count == 0)

    ⛔ NOTHING GATES ON THIS. It is here for ONE reason: the claim "the per-name
    rule is STRONGER than the count" is a comparison between two rules, and a
    comparison needs both of them present to be measured rather than asserted.
    `test_two_engine_transport_rule_is_stronger` drives this function and
    `check_two_engine_transport` over the SAME constructed states and reports
    where they disagree. `retired` means it gates nothing.

    ⚠ DO NOT GROW A CALLER. A second consumer would make this a live rule, and
    it must not be one, because it is BOTH unsatisfiable for any app with a secret
    mount AND vacuous about the crash-loop it names — see the module header."""
    return (declared_count > 0) == (env_count == 0)
