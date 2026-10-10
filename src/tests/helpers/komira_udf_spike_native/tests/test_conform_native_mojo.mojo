# The conformance suite against the native runtime (:native) loading the
# Mojo native UDF library
# (//src/tests/helpers/komira_udf_spike_native_mojo:native_mojo), through the
# C ABI only.
#
# What it proves: every case of the corpus but LEFT_OUT passes on a native
# UDF library written in Mojo, behind the native runtime, none skipped. The
# left-out cases each need a fixture that breaks the ABI on purpose (an input
# not moved, an error filled on OK or naming a row outside the batch, a
# malformed output array or table), which the reference runtime has and this
# library does not; every case user code can produce is run, the legal
# output layouts (sliced, null_count -1, no data buffer) included. A Mojo
# package can
# export the table (design section 6.3), read the arrays the host moves in,
# return arrays the host releases, and keep a Mojo error from crossing the
# ABI (raise_on_row_3: the fixture raises a Mojo Error; the library returns
# ERR_RAISED with the row).
#
# Defects caught: a Mojo fixture or entry that breaks the contract: an input
# not moved or released twice, an output left set on failure, a ROW read
# outside the read set that user code catches and the library lets pass, a
# cancel flag not read.
#
# Mutant planted: _fixtures.mojo's RowView.get raising on an undeclared field
# without recording it: red on row_caught_violation ("status OK, expected
# ERR_FIELD_NOT_DECLARED") and row_undeclared_field (no row).

from std.os import getenv
from std.testing import assert_equal

from komira_udf_spike_abi.cases import Case
from komira_udf_spike_abi.conform import load_cases, run_suite
from komira_udf_spike_native.code import code_set

comptime CASES = "src/tests/helpers/komira_udf_spike_abi/cases"
comptime CASE_COUNT = 107


def _left_out() -> List[String]:
    """The cases whose fixture breaks the ABI on purpose."""
    return [
        # inputs not moved, an error filled on OK, a frame answering after
        # its error, an error row outside the batch or left as the host set it
        "fault_args_not_moved_on_error",
        "fault_frame_input_not_moved",
        "fault_frame_input_not_moved_on_error",
        "fault_agg_args_not_moved_on_error",
        "fault_agg_group_ids_not_moved",
        "fault_agg_group_ids_not_moved_on_error",
        "fault_agg_states_not_moved",
        "fault_agg_states_not_moved_on_error",
        "error_released_on_ok",
        "frame_error_released_on_ok",
        "frame_no_next_after_error",
        "fault_error_row_below_minus_one",
        "fault_error_row_past_batch",
        "fault_error_row_past_batch_propagate",
        "error_row_left_unset",
        # malformed output columns
        "fault_output_buffers_null",
        "fault_output_data_null",
        "fault_output_data_null_one_row",
        "fault_output_device_id",
        "fault_output_dictionary",
        "fault_output_n_buffers_3",
        "fault_output_n_children_1",
        "fault_output_negative_length",
        "fault_output_negative_offset",
        "fault_output_null_count_below",
        "fault_output_null_count_zero",
        "fault_output_release_keeps_slot",
        "fault_output_sync_event",
        # malformed output tables
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
        "fault_table_null_count_lies",
        "fault_table_null_count_zero",
        "fault_table_null_rows",
        "fault_table_out_on_error",
    ]


def main() raises:
    var all = load_cases(CASES)
    assert_equal(len(all), CASE_COUNT, "cases loaded from " + CASES)
    var left_out = _left_out()
    var cases = List[Case]()
    for i in range(len(all)):
        if all[i].name not in left_out:
            cases.append(all[i].copy())
    # Every left-out name is a case of the corpus: a misspelt name would run
    # the case it meant to leave out, and a renamed case would be dropped
    # unseen.
    assert_equal(len(cases), CASE_COUNT - len(left_out), "a left-out name is not a case of the corpus")
    var code = code_set("./native_mojo.so", getenv("TMPDIR") + "/code")
    var report = run_suite("./native.so", cases, code)
    print(report)
    assert_equal(report.runtime_id, "komira/native")
    assert_equal(report.count("FAIL"), 0, "cases failed on the native Mojo library")
    assert_equal(report.count("SKIP"), 0, "cases skipped on the native Mojo library")
    assert_equal(report.count("PASS"), len(cases) + 1, "every case run and the capabilities check pass")
    print("test_conform_native_mojo: ok")
