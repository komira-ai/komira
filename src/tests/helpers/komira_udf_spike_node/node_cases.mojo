# The shared conformance cases (komira_udf_spike_abi/cases) as the Node
# runtime runs them.
#
# The corpus names each fixture by a bare name (`double`) that each runtime
# implements in its language (design section 6.3). This runtime's entries are
# `<bundle>.js#<export>`, so every entry becomes `fixtures.js#<name>`.
#
# Eight cases are left out.
#   - Seven are runtime bugs, not user code: an output with the wrong layout,
#     an input not moved, OK without an output, an output on another device,
#     a null_count that lies, `out` left set on an error, an aggregate input
#     not moved. A TypeScript function cannot commit them; only a runtime
#     written to break the ABI can, which is what komira-test/echo-broken is
#     for.
#   - One needs a declared signature to check: validate_wrong_signature
#     declares float64 arguments for a function written for int64. A
#     TypeScript function declares nothing at run time (its types are erased),
#     so the plan's types are the only signature and nothing can contradict
#     them before a call.
# Everything else runs, the frame that never ends (fault_frame_never_ends)
# included: a generator is user code.

from komira_udf_spike_abi.cases import Case
from komira_udf_spike_abi.conform import load_cases

comptime BUNDLE = "fixtures.js"


def left_out_cases() -> List[String]:
    """The cases the Node runtime does not run (above)."""
    return [
        "bad_output_layout",
        "fault_agg_args_not_moved",
        "fault_args_not_moved",
        "fault_null_count_contradicts_validity",
        "fault_ok_without_output",
        "fault_out_set_on_error",
        "fault_output_not_on_cpu",
        "validate_wrong_signature",
    ]


def select_cases(all: List[Case], left_out: List[String]) raises -> List[Case]:
    """`all` but the cases named in `left_out`, each entry rewritten to
    `fixtures.js#<name>`. Raises UDF_CASES_CHANGED when a name in `left_out`
    is not among `all` (the list went stale)."""
    var out = List[Case]()
    var dropped = 0
    for i in range(len(all)):
        var c = all[i].copy()
        if c.name in left_out:
            dropped += 1
            continue
        if c.spec.entry != "":
            c.spec.entry = BUNDLE + "#" + c.spec.entry
        out.append(c^)
    if dropped != len(left_out):
        raise Error(
            "UDF_CASES_CHANGED: " + String(dropped) + " of the " + String(len(left_out))
            + " left-out cases are in the corpus"
        )
    return out^


def node_cases(dir: String) raises -> List[Case]:
    """The cases under `dir` the Node runtime runs, entries rewritten."""
    return select_cases(load_cases(dir), left_out_cases())
