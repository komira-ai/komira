# =============================================================================
# komira_deploy_bundle/outputs_ref.mojo — the typed `${ref:<bundle>.outputs.
#   <name>}` symbolic reference.
# =============================================================================
#
# The SYNTH-TIME symbolic resolution of a deploy OUTPUT reference. A `${ref:...}`
# is a TYPED symbolic reference (NOT a string template — the "typed symbolic
# refs, no ${} templating" discipline the rest of the bundle grammar enforces for
# `from_build` / wave-output refs). It names a value another bundle EXPOSES as a
# named output, and it is resolved at SYNTH — never interpolated as free-form
# text.
#
# This module is PURE (no registry, no I/O): it PARSES the ref and resolves it
# against a bundle's declared `outputs` to the served-service NAME the output
# exposes (its `from_served`). The URL read — `service/<from_served>` → URL over
# the service registry — is the caller's step, which composes this with the
# registry lookup. Keeping the symbolic half here keeps the authoring package a
# clean leaf (no service-registry or object-store dependency).
#
# FAIL-CLOSED (a dangling ref must never silently resolve to ""):
#   * a malformed ref (not `${ref:<bundle>.outputs.<name>}`, empty <bundle>/<name>)
#   * an unknown output (`<name>` names no declared output)               → raise.
#   * an output with no `from_served` (only the served-URL kind resolves) → raise.
#
# ENCAPSULATION: byte-based substring extraction (the `scaffold.mojo` `_strip`
# idiom — no String slicing API dependence), borrowed reads. No UnsafePointer, no
# wildcard origin. Mojo 1.0.0b2.
# =============================================================================

from komira_rpc_bundle.app_bundle import DeployOutput


# The fixed literals of the `${ref:<bundle>.outputs.<name>}` grammar.
def _ref_open() -> String:
    return String("${ref:")


def _ref_mid() -> String:
    return String(".outputs.")


def _ref_close() -> String:
    return String("}")


@fieldwise_init
struct ParsedOutputRef(Copyable, Movable, Deinitable):
    """A parsed `${ref:<bundle>.outputs.<name>}` — the referenced bundle symbol +
    the output symbol. Flat Strings (gap6 N/A)."""

    var app: String
    var output: String


def is_output_ref(s: String) -> Bool:
    """True iff `s` is a `${ref:...}` reference (opens with `${ref:` and closes
    with `}`) — the discriminator a caller uses to tell a symbolic reference from
    a literal (e.g. an authored `coordinator_ref` that is a plain name/URL)."""
    return s.startswith(_ref_open()) and s.endswith(_ref_close())


def _byte_substr(s: String, start: Int, end: Int) -> String:
    """The bytes `[start, end)` of `s` as a new String (the scaffold.mojo
    byte-copy idiom — no String-slice API dependence). Clamps to bounds."""
    var b = s.as_bytes()
    var out = String("")
    var i = start
    if i < 0:
        i = 0
    while i < end and i < len(b):
        out += chr(Int(b[i]))
        i += 1
    return out^


def _find_sub(hay: String, needle: String) -> Int:
    """The first byte index of `needle` in `hay`, or -1 (a small linear scan;
    the refs are short)."""
    var hb = hay.as_bytes()
    var nb = needle.as_bytes()
    if len(nb) == 0:
        return 0
    if len(nb) > len(hb):
        return -1
    for start in range(len(hb) - len(nb) + 1):
        var ok = True
        for j in range(len(nb)):
            if hb[start + j] != nb[j]:
                ok = False
                break
        if ok:
            return start
    return -1


def parse_output_ref(s: String) raises -> ParsedOutputRef:
    """Parse `${ref:<bundle>.outputs.<name>}` into a `ParsedOutputRef`. Raises a
    clear, self-correctable error on a malformed ref (fail-closed) — a caller that
    reaches this on a NON-ref value should gate with `is_output_ref` first."""
    if not is_output_ref(s):
        raise Error(
            "output ref '"
            + s
            + "' is not of the form ${ref:<bundle>.outputs.<name>}"
        )
    # Strip the `${ref:` head and the trailing `}` -> "<bundle>.outputs.<name>".
    var total = len(s.as_bytes())
    var inner = _byte_substr(s, len(_ref_open().as_bytes()), total - 1)
    var mid = _ref_mid()
    var idx = _find_sub(inner, mid)
    if idx < 0:
        raise Error(
            "output ref '"
            + s
            + "' is malformed: expected ${ref:<bundle>.outputs.<name>}"
        )
    var app = _byte_substr(inner, 0, idx)
    var name = _byte_substr(inner, idx + len(mid.as_bytes()), len(inner.as_bytes()))
    if app.byte_length() == 0 or name.byte_length() == 0:
        raise Error(
            "output ref '"
            + s
            + "' is malformed: <bundle> and <name> must both be non-empty"
        )
    return ParsedOutputRef(app^, name^)


def lookup_output(
    outputs: List[DeployOutput], name: String
) -> Optional[DeployOutput]:
    """The declared output named `name`, or None (the caller fail-closes on
    None)."""
    for ref o in outputs:
        if o.name == name:
            return Optional[DeployOutput](o.copy())
    return Optional[DeployOutput]()


def resolve_output_to_served_name(
    ref_str: String, outputs: List[DeployOutput]
) raises -> String:
    """The SYNTH-TIME symbolic resolution: `${ref:<bundle>.outputs.<name>}` ->
    the served-service NAME the output exposes (its `from_served`). PURE — does
    NOT read the registry; the returned name is what a caller then resolves to a
    URL via `service/<name>` in the service registry.

    Fail-closed: a malformed ref, an unknown output, or a non-served
    output (no `from_served`) each RAISES with a clear message — a dangling ref
    never silently resolves."""
    var parsed = parse_output_ref(ref_str)
    var found = lookup_output(outputs, parsed.output)
    if not found:
        raise Error(
            "output ref '"
            + ref_str
            + "' names no declared output '"
            + parsed.output
            + "' (bundle '"
            + parsed.app
            + "')"
        )
    ref o = found.value()  # borrow (DeployOutput is not ImplicitlyCopyable)
    if o.from_served.byte_length() == 0:
        raise Error(
            "output '"
            + o.name
            + "' is not a served-URL output (no 'from_served') — only served-URL"
            + " outputs are resolvable"
        )
    return String(o.from_served)
