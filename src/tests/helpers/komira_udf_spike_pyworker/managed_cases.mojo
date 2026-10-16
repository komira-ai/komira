# The shared conformance cases (komira_udf_spike_abi/cases) as a managed
# runtime runs them.
#
# The corpus names each fixture by a bare name (`double`) that each runtime
# implements in its language (design section 6.3). This runtime's entries are
# `module:function`, so every entry becomes `udf_fixtures:<name>`.
#
# 79 cases are left out: their fixtures are runtime bugs or output layouts
# that only a runtime's own C code chooses. The bugs: an output or table with
# the wrong layout, buffers or device, a null_count that lies, OK without an
# output, `out` left set on an error, an input not moved (on OK or on an
# error), an error row outside the batch or left unset, an error filled on
# OK, a frame that never ends or answers after its error, an aggregate that
# refuses a second group set per instance. The legal layout edges: an empty
# output without a data buffer, null_count -1, an output or table at a
# nonzero offset. What a runtime's C side does with the Arrow structs: a
# child array moved out and released on its own, the borrowed schemas'
# flags read back. A runtime's user code cannot commit any of them;
# only a runtime written to break the ABI can, which is what
# komira-test/echo-broken is for. Fifteen more are settings of the reference
# runtime, or need what this runtime does not do, or validate shapes it
# does not declare (each named below).
# Everything else runs, and a case whose
# shape the runtime does not declare is skipped by the runner and reported.

from komira_udf_spike_abi.cases import Case
from komira_udf_spike_abi.conform import load_cases

comptime FIXTURE_MODULE = "udf_fixtures"


def runtime_fault_cases() -> List[String]:
    """The cases whose fixtures are runtime bugs (above)."""
    return [
        "agg_partials_on_own_instances",
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
        "fault_frame_never_ends",
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
        "fault_table_release_keeps_slot",
        "frame_error_released_on_ok",
        "frame_fault_then_raise",
        "frame_no_next_after_error",
        "frame_output_sliced_offset",
        "output_empty_without_data",
        "output_null_count_unknown",
        "output_sliced_offset",
        "schema_flags_exported",
        "table_null_count_unknown",
        # a context lost with no user code run: a test setting of the
        # reference runtime
        "instance_lost_on_agg_open",
        "instance_lost_on_call_batch",
        # a batch function's error naming a row: the adapter reports row -1
        # for any error a batch function raises (komira_udf_pyrt.py, _raised)
        "bisect_half_reports_row",
        # user code catching its input's failure in a frame: this runtime
        # declares no frames
        "nested_frame_input_error_caught",
        # descriptors of ROW and MAP_BATCHES_FRAME (read sets, recorded
        # fields): this runtime declares neither shape, so the host refuses
        # the validate from describe before it reaches the runtime
        # (OPTIMIZED_UDF_KIND_UNSUPPORTED), and the case cannot hold
        "validate_read_set_call_order",
        "validate_read_set_mismatch",
        "validate_read_set_present_empty",
        "validate_read_set_present_empty_vs_a",
        "validate_read_set_type_differs",
        "validate_read_set_union_with_key",
        "validate_recorded_fields_absent_managed",
        "validate_recorded_fields_repeated_name",
        "validate_recorded_fields_unsorted",
        "validate_recorded_key_fields_unsorted",
        "validate_recorded_key_in_fields",
    ]


def managed_cases(dir: String) raises -> List[Case]:
    """The cases under `dir` but the runtime-fault ones, each entry
    rewritten to `udf_fixtures:<name>`. Raises UDF_CASES_CHANGED when a name
    in runtime_fault_cases() is not in the corpus (the list went stale)."""
    var all = load_cases(dir)
    var faults = runtime_fault_cases()
    var out = List[Case]()
    var dropped = 0
    for i in range(len(all)):
        var c = all[i].copy()
        if c.name in faults:
            dropped += 1
            continue
        if c.spec.entry != "":
            c.spec.entry = FIXTURE_MODULE + ":" + c.spec.entry
        out.append(c^)
    if dropped != len(faults):
        raise Error(
            "UDF_CASES_CHANGED: " + String(dropped) + " of the "
            + String(len(faults)) + " runtime-fault cases are in " + dir
        )
    return out^
