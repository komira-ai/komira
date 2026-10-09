# =============================================================================
# src/kci_release_machine/tests/test_release_machine_field_names.mojo
#   The machine file's field names are an authored contract: this golden
#   list pins them, so renaming one is a visible edit here.
# =============================================================================

from std.testing import TestSuite, assert_equal

from kci_release_machine import machine_field_names


def test_the_field_names_are_the_golden_list() raises:
    var got = machine_field_names()
    var want = List[String]()
    want.append(String("schema_version"))
    want.append(String("name"))
    want.append(String("stage"))
    want.append(String("stage.name"))
    want.append(String("stage.after"))
    want.append(String("stage.environment"))
    want.append(String("stage.farm_connected"))
    want.append(String("stage.trigger"))
    want.append(String("stage.break_glass"))
    want.append(String("stage.break_glass_environment"))
    want.append(String("stage.step"))
    want.append(String("step.name"))
    want.append(String("step.kind"))
    want.append(String("step.platform"))
    want.append(String("step.artifacts"))
    want.append(String("step.channels"))
    want.append(String("step.channel"))
    want.append(String("step.cells"))
    want.append(String("step.cell"))
    want.append(String("step.resources"))
    want.append(String("step.definitions"))
    want.append(String("step.validation"))
    want.append(String("validation.name"))
    want.append(String("validation.kind"))
    want.append(String("validation.image"))
    want.append(String("validation.install"))
    want.append(String("validation.compiler_channel"))
    want.append(String("validation.extra_channel"))
    want.append(String("validation.program"))
    want.append(String("validation.smoke"))
    want.append(String("validation.wait_for_index_seconds"))
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
