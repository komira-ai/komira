# =============================================================================
# kci_params/app_params.mojo — ★ A MANAGED APP DECLARES ITS PARAMETERS,
#   AND THE CONTROL PLANE LEARNS ONLY THAT PARAMETERS EXIST.
#
#   Design requirements:
#     * a managed app is an INSTANCE of a deploy pattern, not a fork; it takes
#       generic parameters, and the deploy path plumbs them in through the
#       kci libraries. The control plane knows only about generic
#       parameters, never anything specific to one app;
#     * parameters are passed as COMMAND-LINE ARGUMENTS, not as environment
#       variables;
#     * a value that names another deploy item is a REFERENCE to that item,
#       resolved once, rather than a literal hardcoded in several places.
# =============================================================================
#
# ── WHAT GOES WRONG WITHOUT IT ───────────────────────────────────────────────
# A managed app configured through hand-authored environment variables is a
# FORK: it needs a set of variables that no artifact declares, that nothing
# checks, and whose meaning the control plane has to know. Configuration then
# goes inert in both directions: variables read by code that no deploy artifact
# declares, and variables declared by deploy artifacts that no code reads.
# Nothing reports either.
#
# Three failure shapes follow from that, and each one is a design input here:
#
#   1. A FEATURE SHIPS DISABLED because the variable that arms it is set by
#      nothing but a README — and the READ SITE HAS A DEFAULT, so an unset
#      variable is indistinguishable from a configured one. See
#      `_reject_default_on_required` below: this module refuses to let a
#      REQUIRED parameter carry a default, because a default on a required
#      parameter is precisely the thing that makes a gap invisible.
#   2. DATA LANDS IN A SCRATCH DIRECTORY because the variable naming its real
#      home is set by nothing. Same shape.
#   3. A VARIABLE PINNED BY NO TEST, so a one-word typo in its name fails every
#      request silently. A parameter NAME is checked at both ends here — the
#      renderer refuses an unknown name (NO PHANTOM) and the parser refuses an
#      unknown flag.
#
# ── ⚠ WHY argv AND NOT env — THIS IS THE POINT, NOT A PREFERENCE ─────────────
# An environment variable is read at an arbitrary point deep in a call stack,
# untyped, with no schema and no provenance, and its absence is discovered in
# production or not at all. That is not an analogy for the three shapes above; it
# is the mechanism of all three.
#
# An ARGUMENT is parsed at ONE site, at startup, against a DECLARED set. A missing
# required one fails at parse time, loudly, before the process serves anything, and
# the effective configuration of a running revision is legible in its own command
# line — in the revision spec, in the plan diff, in `describe` output.
#
# ── ⚠ AND THAT IS EXACTLY WHY SECRETS STAY REFERENCES ────────────────────────
# argv is WORLD-READABLE: `/proc/<pid>/cmdline` is mode 0444, and the same string
# lands in `ps`, in the Cloud Run revision spec, in every `describe` output and in
# the plan diff. So a secret parameter renders the secret's NAME
# (`projects/P/secrets/S/versions/latest`) and the app resolves the VALUE at boot
# under its own workload identity. A resource name is not a capability — reading it
# grants nothing without an IAM accessor binding on that resource.
#
# This module therefore has NO API that can put a secret value into a rendered
# surface: `PARAM_KIND_SECRET_REFERENCE` is enforced (`_reject_literal_on_injected`)
# to be reachable only through the reference channel, and the residency of the
# reference itself is checked by the deploy renderer's typed references, which
# are the ONE reference concept for deploys. This module deliberately does NOT
# define a second one — see §5.
#
# ── THE OBLIGATION VOCABULARY — AND ITS ONE REFINEMENT ───────────────────────
# The three obligation codes (`R` required, `I` runner-injected, `O` optional)
# are the vocabulary a per-binary env contract uses, together with the three
# properties it enforces: NO PHANTOM / NO GAP / NO LEAK. The vocabulary is kept
# rather than replaced, because a second one would mean two answers to "is this
# required" in one deploy path.
#
# It is refined in exactly one place, and the refinement is what makes the argv
# channel stronger than the env channel:
#
#   IN AN ENV CONTRACT, `I:` IS AN UNKEEPABLE PROMISE. There it means "do not put
#   this in the bundle; a runner injects it out of band." Nothing can check that a
#   runner did, so a contract can carry `I:` keys that no runner ever injects: the
#   contract is satisfied, every guard is green, and the step can only ever exit
#   non-zero on its first read. An `I:` nobody injects is indistinguishable, to
#   every gate, from wiring that works.
#
#   HERE `I:` IS A TYPE, NOT A PROMISE. The bundle DOES author an `I:` parameter —
#   it is rendered into argv like any other — but its value is CONSTRAINED to be a
#   reference (`PARAM_KIND_REFERENCE` / `PARAM_KIND_SECRET_REFERENCE`), never a
#   literal. So "the value must not be a checked-in literal" stops being a rule an
#   operator has to remember and becomes a thing the declaration cannot express.
#   NO LEAK is enforced by construction instead of by inspection.
#
# ── WHAT THE CONTROL PLANE MAY KNOW ──────────────────────────────────────────
# THAT parameters exist, their names as OPAQUE strings, their kind ordinal, and
# their value-or-reference as an opaque string. Nothing IN THIS MODULE names any
# specific parameter of any specific app.
#
# "The control plane does not know what a managed app is" is a property of the
# control plane's BINARIES, not of a leaf value type, so it is not this module's to
# measure: it has to be checked against the control plane's own source, where it
# lives.
#
# ── ENCAPSULATION ────────────────────────────────────────────────────────────
# ZERO deps. Pure value types (flat `String`/`Int`) + string helpers: no I/O, no
# process state, no cloud, no DB, no FFI. ZERO UnsafePointer crosses any boundary;
# no wildcard origin. That is deliberate and load-bearing — this leaf is consumed by
# THREE sides that must not depend on each other: the DEPLOY renderer (kci),
# the APP's startup parser (a serving binary), and the CONTROL PLANE's opaque store.
# A shared mechanism with a dep closure would not be adoptable by all three, and two
# copies of a parameter contract is the fork this whole mechanism exists to end.
# Mojo 1.0.0b2 (def-only).
# =============================================================================


# =============================================================================
# §1 — THE OBLIGATION CODES. The env-contract vocabulary, kept verbatim and
#      refined for argv as documented in the header.
# =============================================================================

comptime PARAM_REQUIRED: String = "R"
"""REQUIRED / SUPPLIED-BY-THE-DEPLOY. The app cannot run without it AND it is
plain config, so the DEPLOY must supply a value. A missing one is refused AT RENDER
TIME (`render_app_params`) and again AT PARSE TIME (`parse_app_params`) — the two
ends of the same wire, so a value that never reached the renderer and a value the
renderer dropped are both loud."""

comptime PARAM_RUNNER_INJECTED: String = "I"
"""REQUIRED / REFERENCE-ONLY. The app cannot run without it, and its value is a
SECRET or a per-run identity, so what travels is a REFERENCE and never the value.

★ THIS IS THE REFINEMENT OVER THE ENV-ERA `I:` (header). In the env world this code
meant "a runner injects it out of band", which nothing could check: an `I:` key
that no runner ever injects satisfies every gate. Here the deploy DOES
author it; the declaration simply cannot express a literal for it."""

comptime PARAM_OPTIONAL: String = "O"
"""OPTIONAL. Has a DECLARED default, and the default is declared HERE — not at a
read site buried in the app — so the effective value is a property of the
declaration rather than of whichever call site got there first."""


def param_obligation_label(obligation: String) -> String:
    """The human word for an obligation code, used in every refusal so an operator
    reads "REQUIRED" rather than "R"."""
    if obligation == PARAM_REQUIRED:
        return String("REQUIRED")
    if obligation == PARAM_RUNNER_INJECTED:
        return String("REQUIRED (reference-only)")
    if obligation == PARAM_OPTIONAL:
        return String("OPTIONAL")
    return String("UNKNOWN('") + obligation + String("')")


def param_obligation_is_required(obligation: String) -> Bool:
    """True for the two codes a deploy MUST satisfy. One predicate, so the renderer
    and the parser cannot disagree about which codes are mandatory."""
    return (
        obligation == PARAM_REQUIRED or obligation == PARAM_RUNNER_INJECTED
    )


# =============================================================================
# §2 — THE KIND CODES. What a parameter's value IS — which decides how the deploy
#      is allowed to produce it, and which residency rule applies to it.
# =============================================================================

comptime PARAM_KIND_LITERAL: Int = 0
"""A plain configuration value, rendered verbatim (a name, a path, a duration, a
region). Safe to publish; carries no residency rule."""

comptime PARAM_KIND_REFERENCE: Int = 1
"""A reference to ANOTHER DEPLOY ITEM — a served endpoint, a bucket, a datastore,
an image. The value is RESOLVED ONCE at render time from the item it names, not
copied into every bundle that needs it.

A literal copied into several bundles drifts from the item it names;
resolving it once, from that item, removes the copies."""

comptime PARAM_KIND_SECRET_REFERENCE: Int = 2
"""A SECRET's resource NAME. The value NEVER travels; the app resolves it at boot
under its own workload identity. See the header for why the world-readability of
argv is the REASON for this rather than an obstacle to it."""


def param_kind_label(kind: Int) -> String:
    """The human word for a kind ordinal, used in every refusal."""
    if kind == PARAM_KIND_LITERAL:
        return String("LITERAL")
    if kind == PARAM_KIND_REFERENCE:
        return String("REFERENCE")
    if kind == PARAM_KIND_SECRET_REFERENCE:
        return String("SECRET_REFERENCE")
    return String("UNKNOWN(") + String(kind) + String(")")


def param_kind_is_reference(kind: Int) -> Bool:
    """True for the two kinds whose value names another item rather than being one.
    These are the kinds a residency rule applies to."""
    return kind == PARAM_KIND_REFERENCE or kind == PARAM_KIND_SECRET_REFERENCE


# =============================================================================
# §3 — AppParamDecl — ONE declared parameter.
# =============================================================================


struct AppParamDecl(Copyable, Movable, Deinitable):
    """One parameter a managed app DECLARES it takes.

    The declaration is authored ONCE, next to the app, and is the single input to
    BOTH ends of the wire: the deploy renders argv from it and the app parses argv
    against it. That is what makes a managed app an INSTANCE rather than a fork —
    the deploy path holds no per-app knowledge, only this record."""

    var name: String
    """The FLAG name WITHOUT the leading `--` (e.g. `example-name`). Rendered as
    `--<name>=<value>`; parsed from either `--<name>=<value>` or `--<name> <value>`
    (both spellings, because a hand-written flag arm that handles only one of
    them — or neither — makes the flag unpassable)."""

    var obligation: String
    """`R` / `I` / `O` — §1."""

    var kind: Int
    """`PARAM_KIND_*` — §2."""

    var default_value: String
    """The value used when an `O:` parameter is not supplied. MUST be empty for a
    required parameter — see `_reject_default_on_required`."""

    var doc: String
    """What this parameter MEANS, in the app's own words. The control plane never
    reads it; it exists so a refusal can quote it and so the declaration is the
    documentation instead of a README that drifts (a variable set by nothing BUT
    a README is set by nothing)."""

    def __init__(
        out self,
        name: String,
        obligation: String,
        kind: Int,
        default_value: String,
        doc: String,
    ):
        self.name = name.copy()
        self.obligation = obligation.copy()
        self.kind = kind.copy()
        self.default_value = default_value.copy()
        self.doc = doc.copy()

    def flag(self) -> String:
        """The rendered flag token `--<name>`. THE ONLY spelling — every surface
        goes through it, so a renderer cannot invent a form the parser rejects."""
        return String("--") + self.name

    def is_required(self) -> Bool:
        return param_obligation_is_required(self.obligation)


# =============================================================================
# §4 — DECLARATION VALIDATION. A malformed declaration is refused before it can
#      render anything, because a declaration is the only thing both ends trust.
# =============================================================================


def _is_kebab_byte(b: UInt8) -> Bool:
    """`a`-`z`, `0`-`9`, `-`. Deliberately NARROW: a parameter name is also a
    column value in the control plane's opaque store and a token in a rendered
    command line, and every widening of this set is a place where the two
    representations can disagree."""
    if b >= UInt8(97) and b <= UInt8(122):
        return True
    if b >= UInt8(48) and b <= UInt8(57):
        return True
    if b == UInt8(45):
        return True
    return False


def validate_param_name(name: String) raises:
    """Refuse a name that cannot round-trip through argv and through the store.

    Refuses: empty, a leading `--` (the flag prefix is added by `flag()`, and a
    name that carries its own is rendered `----x`), a leading or trailing `-`, and
    any byte outside lowercase-kebab. `=` and whitespace are excluded by the byte
    set — both would split a rendered token in two."""
    if name.byte_length() == 0:
        raise Error(
            String(
                "app params: a parameter with an EMPTY name was declared. A"
                " nameless parameter renders as a bare `--=<value>`, which no"
                " parser can attribute to anything"
            )
        )
    if name.startswith("-"):
        raise Error(
            String("app params: parameter name '")
            + name
            + String(
                "' starts with '-'. Declare the BARE name; the `--` prefix is"
                " added by `AppParamDecl.flag()` so exactly one site spells it"
            )
        )
    if name.endswith("-"):
        raise Error(
            String("app params: parameter name '")
            + name
            + String("' ends with '-'")
        )
    var b = name.as_bytes()
    for i in range(len(b)):
        if not _is_kebab_byte(b[i]):
            raise Error(
                String("app params: parameter name '")
                + name
                + String(
                    "' contains a byte outside lowercase-kebab ([a-z0-9-]). A"
                    " parameter name is BOTH an argv token and an opaque key in"
                    " the control plane's store; a byte that means something to"
                    " one of those and not the other is how the two"
                    " representations drift"
                )
            )


def _reject_default_on_required(decl: AppParamDecl) raises:
    """★ A REQUIRED PARAMETER MAY NOT CARRY A DEFAULT.

    This is the rule that catches a feature shipping disabled. When a variable
    that arms a feature is set by nothing but a README, and its READ SITE HAS A
    DEFAULT, an unconfigured deploy and a configured one produce the same
    observable behaviour at boot, in every environment, and the only signal is
    the feature's silence.

    A default on a required parameter is not a convenience; it is the mechanism
    that converts "nobody supplied this" into "it looks supplied". If a value is
    genuinely fine to omit, the parameter is `O:` and says so."""
    if decl.is_required() and decl.default_value.byte_length() > 0:
        raise Error(
            String("app params: parameter '")
            + decl.name
            + String("' is ")
            + param_obligation_label(decl.obligation)
            + String(
                " and also declares a default ('"
            )
            + decl.default_value
            + String(
                "'). A required parameter may not have one: a default makes an"
                " UNSUPPLIED value indistinguishable from a supplied one, which"
                " is exactly how a feature ships disabled in every environment"
                " without a signal. Either drop the default, or declare the parameter"
                " OPTIONAL ('O') and mean it"
            )
        )


def _reject_literal_on_injected(decl: AppParamDecl) raises:
    """★ NO LEAK, ENFORCED BY CONSTRUCTION.

    An `I:` parameter's value is a secret or a per-run identity. In the env-era
    contract that was a PROMISE that a runner would inject it, which nothing could
    check. Here it is a property of the declaration: an `I:` parameter must be a
    REFERENCE kind, so there is no way to declare one whose value is a literal, and
    therefore no way to render one into a world-readable command line."""
    if decl.obligation == PARAM_RUNNER_INJECTED and not param_kind_is_reference(
        decl.kind
    ):
        raise Error(
            String("app params: parameter '")
            + decl.name
            + String(
                "' is declared reference-only ('I') but its kind is "
            )
            + param_kind_label(decl.kind)
            + String(
                ". An 'I' parameter's value is a secret or a per-run identity and"
                " argv is world-readable (/proc/<pid>/cmdline is mode 0444, and"
                " the same string lands in `ps`, the revision spec and the plan"
                " diff). Declare it REFERENCE or SECRET_REFERENCE so the NAME"
                " travels and the app resolves the value at boot"
            )
        )


def validate_param_decls(decls: List[AppParamDecl]) raises:
    """Refuse a malformed declaration SET. Total: every decl is checked, and a
    duplicate name is refused because a duplicate makes `render`/`parse` depend on
    list order — the two sides would silently pick different rows."""
    for i in range(len(decls)):
        var d = decls[i].copy()
        validate_param_name(d.name)
        if (
            d.obligation != PARAM_REQUIRED
            and d.obligation != PARAM_RUNNER_INJECTED
            and d.obligation != PARAM_OPTIONAL
        ):
            raise Error(
                String("app params: parameter '")
                + d.name
                + String("' has unknown obligation code '")
                + d.obligation
                + String("' (expected 'R', 'I' or 'O')")
            )
        if (
            d.kind != PARAM_KIND_LITERAL
            and d.kind != PARAM_KIND_REFERENCE
            and d.kind != PARAM_KIND_SECRET_REFERENCE
        ):
            raise Error(
                String("app params: parameter '")
                + d.name
                + String("' has unknown kind ordinal ")
                + String(d.kind)
            )
        _reject_default_on_required(d)
        _reject_literal_on_injected(d)
        for j in range(i + 1, len(decls)):
            if decls[j].name == d.name:
                raise Error(
                    String("app params: parameter '")
                    + d.name
                    + String(
                        "' is declared TWICE. Which row wins would depend on list"
                        " order, and the renderer and the parser scan in"
                        " different directions"
                    )
                )


def find_param_decl(
    decls: List[AppParamDecl], name: String
) raises -> AppParamDecl:
    """The declaration for `name`, or a LOUD refusal naming what IS declared.

    TOTAL by design, as an env contract is: a parameter nobody
    declared is a parameter nobody has checked, and returning a silent absence for
    it is the fail-quiet this mechanism exists to end."""
    for i in range(len(decls)):
        if decls[i].name == name:
            return decls[i].copy()
    var known = String("")
    for i in range(len(decls)):
        if i > 0:
            known += String(", ")
        known += decls[i].name
    raise Error(
        String("app params: no parameter named '")
        + name
        + String("' is declared. Declared parameters: [")
        + known
        + String("]")
    )


# =============================================================================
# §5 — AppParamValue — one SUPPLIED value, as the deploy authored it.
#
# ⚠ THE `kind` HERE IS THE SUPPLIER'S CLAIM, and the renderer checks it against the
# DECLARATION rather than trusting it. A bundle that supplies a LITERAL for a
# parameter the app declared SECRET_REFERENCE is the leak; a bundle that supplies a
# reference for a literal parameter is a value the app will fail to interpret.
#
# ⚠ AND THERE IS NO SECOND REFERENCE CONCEPT HERE. The RESIDENCY of a reference —
# a secret ref must be EXTERNAL (it points into a separate project that holds
# the secret), an image ref must be LOCAL (a customer account
# can only pull from its own registry) — is decided by the deploy renderer's
# typed references, which carry those rules and their tests. This module carries
# the KIND; that one carries the RESIDENCY. A third concept is exactly what the
# design forbids.
# =============================================================================


struct AppParamValue(Copyable, Movable, Deinitable):
    """One parameter value a deploy supplies for one parameter name."""

    var name: String
    var value: String
    var kind: Int
    """What the SUPPLIER says this value is. Checked against the declaration."""

    def __init__(out self, name: String, value: String, kind: Int):
        self.name = name.copy()
        self.value = value.copy()
        self.kind = kind.copy()


def literal_param(name: String, value: String) -> AppParamValue:
    """A plainly-authored configuration value."""
    return AppParamValue(name, value, PARAM_KIND_LITERAL)


def reference_param(name: String, resolved: String) -> AppParamValue:
    """A value RESOLVED from another deploy item at render time. The caller
    resolves the item; what lands here is the resolution, tagged as one, so the
    renderer can tell it apart from a literal somebody typed."""
    return AppParamValue(name, resolved, PARAM_KIND_REFERENCE)


def secret_reference_param(
    name: String, resource_name: String
) -> AppParamValue:
    """A SECRET's resource NAME. There is deliberately no sibling that takes bytes:
    see the module header. If a caller finds itself wanting to pass the value here
    "just for local testing", that is the change that lands a production seed in a
    revision spec."""
    return AppParamValue(name, resource_name, PARAM_KIND_SECRET_REFERENCE)


def find_param_value(
    values: List[AppParamValue], name: String
) -> Optional[AppParamValue]:
    """The supplied value for `name`, or an absence. NOT total — absence is a
    legitimate answer here (an unsupplied `O:`), and the REQUIRED case is refused
    by `render_app_params` with a message that can name the app."""
    for i in range(len(values)):
        if values[i].name == name:
            return Optional[AppParamValue](values[i].copy())
    return Optional[AppParamValue]()


# =============================================================================
# §6 — THE RENDER. Declaration + supplied values -> argv.
#
# The three properties are the SAME three an env-contract check enforces, moved
# from a test-harness registry onto the product's own deploy path:
#
#   NO PHANTOM — every value a deploy supplies is one the app declares.
#   NO GAP     — every required parameter is supplied.
#   NO LEAK    — an 'I' parameter's value is a reference, never a literal.
# =============================================================================


def render_app_params(
    app: String,
    decls: List[AppParamDecl],
    values: List[AppParamValue],
) raises -> List[String]:
    """Render the argv a deployed managed app receives, or REFUSE naming what is
    wrong and which app it is wrong for.

    `app` is used ONLY in refusal text. Nothing about the rendering depends on
    WHICH app this is — that is the whole claim.

    An unsupplied `O:` with a non-empty default IS rendered, deliberately: the
    effective configuration of a running revision should be legible in the
    revision's own command line rather than inferred from a read-site default
    nobody can see. An `O:` with an empty default is omitted (rendering `--x=`
    would assert an empty value the app cannot distinguish from absence)."""
    validate_param_decls(decls)

    # NO PHANTOM. Checked FIRST: a misspelled name is far more likely than a
    # missing one, and reporting "required parameter X was not supplied" when the
    # deploy supplied `X-` sends the reader to the wrong side of the wire.
    for i in range(len(values)):
        var v = values[i].copy()
        var declared = False
        for j in range(len(decls)):
            if decls[j].name == v.name:
                declared = True
                break
        if not declared:
            var known = String("")
            for j in range(len(decls)):
                if j > 0:
                    known += String(", ")
                known += decls[j].name
            raise Error(
                String("app params: PHANTOM PARAMETER — the deploy of '")
                + app
                + String("' supplies '")
                + v.name
                + String(
                    "', which the app declares nowhere. Nothing will read it."
                    " Declared parameters: ["
                )
                + known
                + String("]")
            )
        for j in range(i + 1, len(values)):
            if values[j].name == v.name:
                raise Error(
                    String("app params: the deploy of '")
                    + app
                    + String("' supplies '")
                    + v.name
                    + String(
                        "' TWICE. Which one reaches the app would depend on scan"
                        " order"
                    )
                )

    var argv = List[String]()
    for i in range(len(decls)):
        var d = decls[i].copy()
        var supplied = find_param_value(values, d.name)

        if not supplied:
            # NO GAP — the property that catches a feature shipping disabled.
            if d.is_required():
                raise Error(
                    String("app params: NO GAP VIOLATED — the deploy of '")
                    + app
                    + String("' supplies no value for '")
                    + d.name
                    + String("' (")
                    + param_obligation_label(d.obligation)
                    + String("). The app declares it as: ")
                    + d.doc
                    + String(
                        " . A required parameter with no value is a deploy that"
                        " cannot serve; refusing at RENDER time rather than"
                        " letting the revision go Ready and fail silently"
                    )
                )
            if d.default_value.byte_length() > 0:
                argv.append(
                    d.flag() + String("=") + d.default_value
                )
            continue

        var v = supplied.value().copy()

        # NO LEAK. The declaration already forbids an 'I' parameter from being a
        # literal KIND (`_reject_literal_on_injected`); this is the SUPPLY side of
        # the same rule — a bundle must not hand a literal to a reference-kind
        # parameter.
        if param_kind_is_reference(d.kind) and v.kind == PARAM_KIND_LITERAL:
            raise Error(
                String("app params: NO LEAK VIOLATED — the deploy of '")
                + app
                + String("' supplies a LITERAL for '")
                + d.name
                + String("', which the app declares ")
                + param_kind_label(d.kind)
                + String(
                    ". A reference parameter's value must be RESOLVED from the"
                    " item it names, once, at render time — not copied in as a"
                    " literal. For a SECRET_REFERENCE the literal would be the"
                    " secret itself, published into a world-readable command"
                    " line"
                )
            )
        if d.kind == PARAM_KIND_LITERAL and param_kind_is_reference(v.kind):
            raise Error(
                String("app params: the deploy of '")
                + app
                + String("' supplies a ")
                + param_kind_label(v.kind)
                + String(" for '")
                + d.name
                + String(
                    "', which the app declares LITERAL. The app will read the"
                    " reference text as its value"
                )
            )
        if v.value.byte_length() == 0:
            raise Error(
                String("app params: the deploy of '")
                + app
                + String("' supplies an EMPTY value for '")
                + d.name
                + String(
                    "'. An empty value is indistinguishable from an unsupplied"
                    " one at the app's parse site, so it would satisfy this"
                    " render and then fail — or worse, not fail — at boot"
                )
            )
        argv.append(d.flag() + String("=") + v.value)

    return argv^


# =============================================================================
# §7 — THE PARSE. THE ONE SITE, at startup, in the app.
#
# ⚠ BOTH SPELLINGS, AND THE REASON IS A REAL BUG SHAPE. A hand-written flag arm
# that reads its value but never advances the index, with no `--flag=value` arm
# at all, makes the flag unpassable in EITHER spelling — and a green test suite
# misses it when the POLICY is tested and the ARGV WIRING is tested by nothing.
# `parse_app_params` handles both forms in ONE place for EVERY declared
# parameter, so there is no per-parameter arm that can be written wrong.
# =============================================================================


struct AppParamBinding(Copyable, Movable, Deinitable):
    """The resolved parameter values one app process is running with."""

    var names: List[String]
    var values: List[String]

    def __init__(out self):
        self.names = List[String]()
        self.values = List[String]()

    def _put(mut self, name: String, value: String):
        self.names.append(name.copy())
        self.values.append(value.copy())

    def get(self, name: String) raises -> String:
        """The value bound to `name`, or a LOUD refusal. TOTAL: an app asking for a
        parameter it did not declare is a bug in the app, and answering it with an
        empty string is how a typo becomes a silent 503."""
        for i in range(len(self.names)):
            if self.names[i] == name:
                return self.values[i].copy()
        var known = String("")
        for i in range(len(self.names)):
            if i > 0:
                known += String(", ")
            known += self.names[i]
        raise Error(
            String("app params: no parameter '")
            + name
            + String("' is bound. Bound parameters: [")
            + known
            + String(
                "]. An app may only read a parameter it DECLARES — add it to the"
                " declaration so the deploy is obliged to supply it"
            )
        )

    def has(self, name: String) -> Bool:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return True
        return False

    def count(self) -> Int:
        return len(self.names)


def parse_app_params(
    app: String,
    decls: List[AppParamDecl],
    argv: List[String],
) raises -> AppParamBinding:
    """Parse a managed app's declared parameters out of `argv` (INCLUDING argv[0],
    the program name), at startup, at ONE site.

    Refuses, loudly and before the process serves anything:
      * an undeclared `--flag` (the mirror of NO PHANTOM, from the app's side),
      * a declared flag passed with no value,
      * a declared flag passed TWICE,
      * a REQUIRED parameter that is absent — the NO GAP property, enforced at the
        second end of the wire so a value the renderer dropped is as loud as one
        the bundle never supplied.

    ⚠ TOLERATES UNRECOGNISED NON-FLAG TOKENS AND FOREIGN FLAGS? NO. Unknown flags
    are REFUSED. A managed app whose parameters are declared has no other flags to
    take, and silently ignoring one means a deploy can misspell a parameter and see
    a healthy revision — which is the entire class of defect this replaces."""
    validate_param_decls(decls)

    var out = AppParamBinding()
    var seen = List[String]()

    var i = 1
    while i < len(argv):
        var a = argv[i]
        if not a.startswith("--"):
            raise Error(
                String("app params: ")
                + app
                + String(": unexpected argument '")
                + a
                + String(
                    "' — a managed app takes DECLARED parameters as flags, not"
                    " positionals"
                )
            )

        var name: String
        var value: String
        var eq = a.find(String("="))
        if eq >= 0:
            # `--name=value`
            name = String(a[byte=2:eq])
            value = String(a[byte = eq + 1 :])
        else:
            # `--name value` — the two-token form. ★ THE `i += 1` BELOW is the one
            # a hand-written per-flag arm forgets. It happens ONCE, for every
            # parameter, so it cannot be omitted per-arm.
            name = String(a[byte=2:])
            if i + 1 >= len(argv):
                raise Error(
                    String("app params: ")
                    + app
                    + String(": flag '")
                    + a
                    + String("' requires a value")
                )
            value = argv[i + 1].copy()
            i += 1

        # The app's side of NO PHANTOM: raises naming what IS declared.
        var d = find_param_decl(decls, name)

        for j in range(len(seen)):
            if seen[j] == name:
                raise Error(
                    String("app params: ")
                    + app
                    + String(": parameter '")
                    + name
                    + String("' was passed TWICE")
                )
        seen.append(name.copy())

        if value.byte_length() == 0:
            raise Error(
                String("app params: ")
                + app
                + String(": parameter '")
                + name
                + String(
                    "' was passed with an EMPTY value, which is"
                    " indistinguishable from not passing it"
                )
            )
        _ = d
        out._put(name, value)
        i += 1

    # NO GAP, at the app's end.
    for k in range(len(decls)):
        var d2 = decls[k].copy()
        if out.has(d2.name):
            continue
        if d2.is_required():
            raise Error(
                String("app params: ")
                + app
                + String(": REQUIRED parameter '")
                + d2.flag()
                + String("' was not supplied (")
                + param_obligation_label(d2.obligation)
                + String("). The app declares it as: ")
                + d2.doc
                + String(
                    " . Refusing to start: a process that serves without its"
                    " required configuration is the failure mode this"
                    " declaration exists to end"
                )
            )
        if d2.default_value.byte_length() > 0:
            out._put(d2.name, d2.default_value)

    return out^


# =============================================================================
# §8 — THE OPAQUE PROJECTION — what the CONTROL PLANE is allowed to hold.
#
# The CP stores a MAP: `(name, kind, value)` rows. It never names a parameter, and
# it has no arm, enum, column or route per parameter. These two functions are the
# whole of its vocabulary, and they are here rather than in the CP so that the CP
# side has no per-app code at all.
# =============================================================================


def param_map_names(values: List[AppParamValue]) -> List[String]:
    """The parameter NAMES a deployment carries, as opaque strings. Ordered as
    supplied — the CP imposes no ordering because it knows no significance."""
    var out = List[String]()
    for i in range(len(values)):
        out.append(values[i].name.copy())
    return out^


def param_map_is_storable(values: List[AppParamValue]) raises:
    """Refuse a parameter MAP the control plane must not persist.

    ★ THE ONE RULE THE CP CAN ENFORCE WITHOUT KNOWING WHAT ANY PARAMETER MEANS: a
    SECRET_REFERENCE row must hold a REFERENCE, and the only thing a generic store
    can check about that is that it is not obviously a value. A Secret Manager
    resource name always begins `projects/`; a raw seed does not. This is a
    coarse check and says so — the STRUCTURAL guarantee is
    the deploy renderer's external-secret-reference check at render time. This is
    the last net, at the persistence boundary, for a caller that bypassed the
    renderer."""
    for i in range(len(values)):
        var v = values[i].copy()
        if v.kind != PARAM_KIND_SECRET_REFERENCE:
            continue
        if not v.value.startswith("projects/"):
            raise Error(
                String(
                    "app params: refusing to persist parameter '"
                )
                + v.name
                + String(
                    "' — it is declared SECRET_REFERENCE but its value is not a"
                    " resource name (a Secret Manager reference begins"
                    " 'projects/'). The control plane stores REFERENCES to"
                    " secrets and never secret material"
                )
            )


# =============================================================================
# §9 — THE TRANSPORT — how a parameter map crosses the control plane.
#
# ⚠ READ THIS BEFORE ADDING A CHECK HERE. The control plane is a PIPE for
# parameters, and it is a pipe ON PURPOSE. It cannot enforce NO GAP, because
# knowing that a parameter is REQUIRED is knowing something about what that
# parameter MEANS — which is precisely what the design forbids it to know.
#
# So the three properties live at the two ends that DO hold the declaration:
#   * the DEPLOY renderer (`render_app_params`) refuses a missing required value
#     before a revision is ever created,
#   * the APP's startup parser (`parse_app_params`) refuses one again before the
#     process serves anything.
# A value the bundle never supplied and a value the control plane dropped in
# transit are different bugs with the same symptom, and the second end is what
# makes the pipe safe to be dumb.
#
# The CP's one enforceable rule is `param_map_is_storable` (§8): a row it was told
# is a SECRET_REFERENCE must look like a resource name. That check needs no
# knowledge of any specific parameter.
#
# THE WIRE FORMAT is a PREFIXED key in the pipeline job's generic `config`
# string→string map — deliberately, so no schema change is needed anywhere in the
# pipeline and the control plane's code names the PREFIX (generic) and never a
# parameter.
# =============================================================================

comptime APP_PARAM_CONFIG_PREFIX: String = "APP_PARAM:"
"""The job `config` key prefix a managed-app parameter travels under. The control
plane matches on THIS and nothing else — it is the entire vocabulary the CP has
for parameters."""


def app_param_config_key(name: String) -> String:
    """The config key one parameter travels under. ONE spelling, so a writer
    cannot produce a key the reader will not match."""
    return APP_PARAM_CONFIG_PREFIX + name


def is_app_param_config_key(key: String) -> Bool:
    return key.startswith(APP_PARAM_CONFIG_PREFIX)


def app_param_name_from_config_key(key: String) raises -> String:
    if not is_app_param_config_key(key):
        raise Error(
            String("app params: '")
            + key
            + String("' is not a parameter config key (no '")
            + APP_PARAM_CONFIG_PREFIX
            + String("' prefix)")
        )
    return String(key[byte = APP_PARAM_CONFIG_PREFIX.byte_length() :])


def encode_app_param_config_value(kind: Int, value: String) raises -> String:
    """`<kind ordinal>|<value>`.

    THE KIND TRAVELS WITH THE VALUE, and it has to: the control plane cannot ask
    the app what kind a parameter is without learning what the parameter is. `|` is
    the separator because a Secret Manager resource name, a URL and a bucket name
    can all contain `:` and `/` but none may contain `|`."""
    if value.find(String("|")) >= 0:
        raise Error(
            String(
                "app params: a parameter value may not contain '|' (it is the"
                " wire separator between the kind ordinal and the value): '"
            )
            + value
            + String("'")
        )
    return String(kind) + String("|") + value


def decode_app_param_config_value(
    name: String, raw: String
) raises -> AppParamValue:
    """Parse one `<kind>|<value>` config entry back into a typed value.

    Fail-loud on a malformed entry: a partially-understood parameter reaches the
    app as a wrong value, and a wrong value is the failure mode with no signal."""
    var bar = raw.find(String("|"))
    if bar < 0:
        raise Error(
            String("app params: parameter '")
            + name
            + String("' has a malformed transported value (no '|' separating the")
            + String(" kind ordinal from the value): '")
            + raw
            + String("'")
        )
    var kind_text = String(raw[byte=0:bar])
    var value = String(raw[byte = bar + 1 :])
    var kind: Int
    if kind_text == String(PARAM_KIND_LITERAL):
        kind = PARAM_KIND_LITERAL
    elif kind_text == String(PARAM_KIND_REFERENCE):
        kind = PARAM_KIND_REFERENCE
    elif kind_text == String(PARAM_KIND_SECRET_REFERENCE):
        kind = PARAM_KIND_SECRET_REFERENCE
    else:
        raise Error(
            String("app params: parameter '")
            + name
            + String("' was transported with an unknown kind ordinal '")
            + kind_text
            + String("'")
        )
    return AppParamValue(name, value, kind)


def collect_app_params_from_config(
    keys: List[String], values: List[String]
) raises -> List[AppParamValue]:
    """Recover the parameter MAP from a config key/value pair of lists, SORTED BY
    NAME.

    ★ THE SORT IS LOAD-BEARING, NOT COSMETIC. The rendered argv is part of the
    container spec that the reconciler diffs against the live revision to decide
    whether anything changed. A map iteration order that varies between two
    otherwise-identical renders makes every reconcile tick look like a change, and
    the deploy churns a new revision forever. Sorting by name makes the render a
    pure function of the map."""
    if len(keys) != len(values):
        raise Error(
            String(
                "app params: config key/value lists differ in length ("
            )
            + String(len(keys))
            + String(" vs ")
            + String(len(values))
            + String(")")
        )
    var names = List[String]()
    var raws = List[String]()
    for i in range(len(keys)):
        if not is_app_param_config_key(keys[i]):
            continue
        names.append(app_param_name_from_config_key(keys[i]))
        raws.append(values[i].copy())

    # Insertion sort by name (the map is a handful of entries; a stable, obvious
    # sort beats a clever one at this size).
    for i in range(1, len(names)):
        var n = names[i].copy()
        var r = raws[i].copy()
        var j = i - 1
        while j >= 0 and names[j] > n:
            names[j + 1] = names[j].copy()
            raws[j + 1] = raws[j].copy()
            j -= 1
        names[j + 1] = n^
        raws[j + 1] = r^

    var out = List[AppParamValue]()
    for i in range(len(names)):
        if i > 0 and names[i] == names[i - 1]:
            raise Error(
                String("app params: parameter '")
                + names[i]
                + String("' appears TWICE in the transported config")
            )
        out.append(decode_app_param_config_value(names[i], raws[i]))
    return out^


def render_app_param_argv(values: List[AppParamValue]) raises -> List[String]:
    """Render argv from a parameter MAP ALONE — no declaration.

    ⚠ THIS IS THE CONTROL PLANE'S RENDER, AND IT IS DECLARATION-FREE BY DESIGN. It
    cannot check NO GAP (see §9's header) and does not pretend to. What it DOES
    check is the one thing a generic orchestrator can: that a row claiming to be a
    SECRET_REFERENCE carries a reference and not secret material.

    `render_app_params` (§6) is the DECLARED render, used where a declaration
    exists. Both emit `--<name>=<value>` through the same spelling."""
    param_map_is_storable(values)
    var argv = List[String]()
    for i in range(len(values)):
        var v = values[i].copy()
        validate_param_name(v.name)
        if v.value.byte_length() == 0:
            raise Error(
                String("app params: parameter '")
                + v.name
                + String(
                    "' has an EMPTY transported value, which is"
                    " indistinguishable from not supplying it at all"
                )
            )
        argv.append(String("--") + v.name + String("=") + v.value)
    return argv^
