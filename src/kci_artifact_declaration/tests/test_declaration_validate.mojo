# =============================================================================
# src/kci_artifact_declaration/tests/test_declaration_validate.mojo
#   Every refusal of `validate_artifact_declarations`, one case per message.
# =============================================================================
#
# Each case builds a file that is valid except for one thing (the control
# case shows the unbroken file is accepted) and asserts the message names
# that thing. Validation runs inside the parser, so every case goes through
# `parse_artifact_declarations`, the path kci uses. List arguments below are
# `|`-separated; "" is the empty list.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_artifact_declaration import (
    is_valid_declaration_name,
    parse_artifact_declarations,
)

comptime _PREFIX = "decl.textproto: "


def _items(field: String, xs: String) -> String:
    var out = String("")
    if xs.byte_length() == 0:
        return out^
    var parts = xs.split(String("|"))
    for i in range(len(parts)):
        out += String("  ") + field + String(": \"") + String(parts[i]) + String("\"\n")
    return out^


def _bs(
    name: String = String("buck2"),
    exe: String = String("buck2"),
    args: String = String("build|--config-file|/etc/kci/remote.buckconfig"),
) -> String:
    var out = String("build_systems {\n")
    if name.byte_length() > 0:
        out += String("  name: \"") + name + String("\"\n")
    if exe.byte_length() > 0:
        out += String("  executable: \"") + exe + String("\"\n")
    out += _items(String("args"), args)
    return out + String("}\n")


def _art(
    name: String = String("a"),
    bs: String = String("buck2"),
    args: String = String("//pkg:a[release]|--out|{out_dir}"),
) -> String:
    var out = String("artifacts {\n")
    if name.byte_length() > 0:
        out += String("  name: \"") + name + String("\"\n")
    if bs.byte_length() > 0:
        out += String("  build_system: \"") + bs + String("\"\n")
    out += _items(String("args"), args)
    return out + String("}\n")


def _refusal(text: String) -> String:
    try:
        _ = parse_artifact_declarations(text, String("decl.textproto"))
    except e:
        return String(e)
    return String("<parsed>")


def _expect(text: String, message: String) raises:
    assert_equal(_refusal(text), String(_PREFIX) + message)


def test_control_is_accepted() raises:
    assert_equal(_refusal(_bs() + _art()), String("<parsed>"))
    # Two build systems, several artifacts, `{out_dir}` only in the build
    # system's args, inside a longer arg, and braces that are not a
    # placeholder: all accepted.
    assert_equal(
        _refusal(
            _bs()
            + _bs(name = String("packer"), exe = String("/opt/tools/pack"), args = String("--into={out_dir}/pkgs"))
            + _bs(name = String("bare"), args = String(""))
            + _art()
            + _art(name = String("b"), bs = String("packer"), args = String("--set|{}|{k: 1}|{1x}"))
            + _art(name = String("c"), bs = String("bare"), args = String("--out={out_dir}"))
        ),
        String("<parsed>"),
    )


def test_file_refusals() raises:
    _expect(String(""), String("declares no artifact"))
    _expect(_bs(), String("declares no artifact"))


def test_build_system_refusals() raises:
    _expect(_bs(name = String("")) + _art(), String("build system #1 has an EMPTY name"))
    _expect(
        _bs(name = String("Buck-2")) + _art(),
        String("build system 'Buck-2' name is not [a-z][a-z0-9_]*"),
    )
    _expect(_bs() + _bs() + _art(), String("build system 'buck2' is declared twice"))
    _expect(_bs(exe = String("")) + _art(), String("build system 'buck2' has no executable"))
    _expect(
        _bs(exe = String("buck2 --isolation-dir x")) + _art(),
        String("build system 'buck2' executable 'buck2 --isolation-dir x' holds whitespace"),
    )
    # Every whitespace byte, not only the space: a tab, a newline and a CR
    # (textproto escapes, decoded by the lexer) are each refused.
    _expect(
        _bs(exe = String("buck2\\tx")) + _art(),
        String("build system 'buck2' executable 'buck2\tx' holds whitespace"),
    )
    _expect(
        _bs(exe = String("buck2\\nx")) + _art(),
        String("build system 'buck2' executable 'buck2\nx' holds whitespace"),
    )
    _expect(
        _bs(exe = String("buck2\\rx")) + _art(),
        String("build system 'buck2' executable 'buck2\rx' holds whitespace"),
    )
    # An uppercase letter after the first byte is refused too.
    _expect(
        _bs(name = String("aB")) + _art(bs = String("aB")),
        String("build system 'aB' name is not [a-z][a-z0-9_]*"),
    )
    _expect(
        _bs(exe = String("./buck2")) + _art(),
        String(
            "build system 'buck2' executable './buck2' is a relative path"
            " (expected a program name found on PATH, or an absolute path)"
        ),
    )
    _expect(
        _bs(exe = String("tools/buck2")) + _art(),
        String(
            "build system 'buck2' executable 'tools/buck2' is a relative path"
            " (expected a program name found on PATH, or an absolute path)"
        ),
    )
    _expect(
        _bs(args = String("build||--x")) + _art(),
        String("build system 'buck2' arg #2 is empty"),
    )
    _expect(
        _bs(args = String("build|--x={foo}")) + _art(),
        String(
            "build system 'buck2' arg '--x={foo}' holds the unknown placeholder"
            " '{foo}' (the only one is '{out_dir}')"
        ),
    )


def test_artifact_refusals() raises:
    _expect(_bs() + _art(name = String("")), String("artifact #1 has an EMPTY name"))
    _expect(
        _bs() + _art(name = String("komira-json")),
        String("artifact 'komira-json' name is not [a-z][a-z0-9_]*"),
    )
    _expect(
        _bs() + _art(name = String("aB")),
        String("artifact 'aB' name is not [a-z][a-z0-9_]*"),
    )
    _expect(_bs() + _art() + _art(), String("artifact 'a' is declared twice"))
    _expect(_bs() + _art(bs = String("")), String("artifact 'a' names no build_system"))
    _expect(
        _bs() + _art(bs = String("bazel")),
        String("artifact 'a' build_system 'bazel' is not declared"),
    )
    _expect(_bs() + _art(args = String("")), String("artifact 'a' has no args (they say what to build)"))
    _expect(
        _bs() + _art(args = String("//pkg:a||{out_dir}")),
        String("artifact 'a' arg #2 is empty"),
    )
    _expect(
        _bs() + _art(args = String("//pkg:a|--out|{OUT_DIR}")),
        String(
            "artifact 'a' arg '{OUT_DIR}' holds the unknown placeholder"
            " '{OUT_DIR}' (the only one is '{out_dir}')"
        ),
    )
    _expect(
        _bs() + _art(args = String("//pkg:a|--out|/tmp/out")),
        String(
            "artifact 'a' has no '{out_dir}' in its args or in the args of build"
            " system 'buck2': kci could not find what the build made"
        ),
    )


def test_name_predicate() raises:
    assert_true(is_valid_declaration_name(String("komira_json")))
    assert_true(is_valid_declaration_name(String("b2")))
    assert_false(is_valid_declaration_name(String("komira-json")))
    assert_false(is_valid_declaration_name(String("komiraJson")))
    assert_false(is_valid_declaration_name(String("aB")))
    assert_false(is_valid_declaration_name(String("_x")))
    assert_false(is_valid_declaration_name(String("2b")))
    assert_false(is_valid_declaration_name(String("")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
