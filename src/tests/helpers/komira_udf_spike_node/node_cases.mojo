# The shared conformance cases (komira_udf_spike_abi/cases) as the Node
# runtime runs them.
#
# The corpus names each fixture by a bare name (`double`) that each runtime
# implements in its language (design section 6.3). This runtime's entries are
# `<bundle>.js#<export>`, so every entry becomes `fixtures.js#<name>`.
#
# 64 of the corpus's 117 cases are left out; 53 run. A case is left out for one
# of three reasons, and a case user code can express is never among them.
#   - The case needs an ABI-level bug that a TypeScript function cannot
#     commit (about 55 cases). An output with a wrong layout, a NULL buffer, a
#     negative length, a lying null_count, a dictionary, another device, a
#     released child, a null struct row; an input not moved (also on an
#     error); OK without an output; `out` left set on an error; an error that
#     is filled and then OK is returned; an error row the runtime did not see;
#     a frame that answers after its error. The runtime builds every output
#     and every error itself, so only a runtime written to break the ABI can
#     commit them: that is what komira-test/echo-broken is for. A child array
#     a runtime moves out (child_moved_out), schema flags it exports
#     (schema_flags_exported) and a second group set per instance
#     (agg_partials_on_own_instances) are of this kind too.
#   - The case needs a layout this runtime never produces and the user cannot
#     choose: an output at a non-zero offset (output_sliced_offset,
#     frame_output_sliced_offset) or with null_count -1 (output_null_count_unknown,
#     table_null_count_unknown). The runtime always answers offset 0 and an
#     exact null count.
#   - The case needs a fixture the adapter's shape does not allow:
#     agg_finish_short_by_one and agg_state_long_by_one want a finish or a
#     state column of the wrong length, but the adapter calls the user's
#     finish once per group and builds the column itself;
#     validate_wrong_signature declares float64 arguments for a function
#     written for int64, and a TypeScript function declares nothing at run
#     time (its types are erased), so the plan's types are the only signature
#     and nothing can contradict them before a call.
# Everything else runs, the frame that never ends (fault_frame_never_ends)
# included: a generator is user code.

from komira_udf_spike_abi.cases import Case
from komira_udf_spike_abi.conform import load_cases

comptime BUNDLE = "fixtures.js"


def left_out_cases() -> List[String]:
    """The cases the Node runtime does not run (above)."""
    return [
        "agg_finish_short_by_one",
        "agg_partials_on_own_instances",
        "agg_state_long_by_one",
        "bad_output_layout",
        "child_moved_out",
        "error_released_on_ok",
        "error_row_left_unset",
        "fault_agg_args_not_moved",
        "fault_agg_args_not_moved_on_error",
        "fault_agg_group_ids_not_moved",
        "fault_agg_group_ids_not_moved_on_error",
        "fault_agg_states_not_moved",
        "fault_agg_states_not_moved_on_error",
        "fault_args_not_moved",
        "fault_args_not_moved_on_error",
        "fault_error_row_below_minus_one",
        "fault_error_row_minus_two",
        "fault_error_row_past_batch",
        "fault_error_row_past_batch_propagate",
        "fault_frame_input_not_moved",
        "fault_frame_input_not_moved_on_error",
        "fault_null_count_contradicts_validity",
        "fault_ok_without_output",
        "fault_out_set_on_error",
        "fault_output_buffers_null",
        "fault_output_data_null",
        "fault_output_data_null_one_row",
        "fault_output_device_id",
        "fault_output_dictionary",
        "fault_output_n_buffers_3",
        "fault_output_n_children_1",
        "fault_output_negative_length",
        "fault_output_negative_offset",
        "fault_output_not_on_cpu",
        "fault_output_null_count_below",
        "fault_output_null_count_zero",
        "fault_output_release_keeps_slot",
        "fault_output_sync_event",
        "fault_table_buffers_null",
        "fault_table_child_null",
        "fault_table_child_released",
        "fault_table_child_short",
        "fault_table_device",
        "fault_table_dictionary",
        "fault_table_n_buffers_0",
        "fault_table_n_buffers_2",
        "fault_table_n_children_0",
        "fault_table_n_children_2",
        "fault_table_negative_length",
        "fault_table_negative_offset",
        "fault_table_null_count_below",
        "fault_table_null_count_lies",
        "fault_table_null_count_zero",
        "fault_table_null_rows",
        "fault_table_out_on_error",
        "frame_error_released_on_ok",
        "frame_fault_then_raise",
        "frame_no_next_after_error",
        "frame_output_sliced_offset",
        "output_null_count_unknown",
        "output_sliced_offset",
        "schema_flags_exported",
        "table_null_count_unknown",
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
