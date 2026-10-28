# =============================================================================
# src/kci_validate/tests/test_readme_link.mojo
#   The link commands of an installed README (readme_link.mojo): the
#   arguments kci computes for a closure (every shared library, dependents
#   first; static archives on the build line only), the README's
#   `sh komira-link` block read by the real README examples tool kci ships
#   (this test's data), and the install validation's `readme` row
#   (`installed_readme`) refusing a block that differs from what the closure
#   needs. The planted defect of docs/design/native_packaging.md slice 10, a
#   README without an owner's `-l`, is the refusal below; a kci that ran the
#   README with flags of its own, or did not compare, would pass it.
# =============================================================================

from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_release_set.member import file_sha256_hex
from komira_runtime_paths import data_path, test_tmpdir

from kci_validate import (
    InstallPin,
    LinkArgs,
    LinkNode,
    closure_link_args,
    installed_readme,
    link_refusal,
    parse_link_args,
    readme_link_args_of,
    run_link_args,
    run_program_argv,
)


def _names(*xs: String) -> List[String]:
    var out = List[String]()
    for i in range(len(xs)):
        out.append(xs[i].copy())
    return out^


def _closure() -> List[LinkNode]:
    """komira_http_core's shape: app needs http_core, which needs crypto and
    async; async needs libc and log; log ships its holder static and needs
    libc and metrics."""
    var n = List[LinkNode]()
    n.append(LinkNode(String("app"), _names("__glibc", "mojo-compiler", "komira_http_core"), List[String](), List[String]()))
    n.append(LinkNode(String("komira_http_core"), _names("komira_crypto", "komira_async"), _names("komira_http_core_native"), List[String]()))
    n.append(LinkNode(String("komira_crypto"), List[String](), _names("komira_crypto_native"), List[String]()))
    n.append(LinkNode(String("komira_async"), _names("komira_libc", "komira_log"), _names("komira_async_native"), List[String]()))
    n.append(LinkNode(String("komira_log"), _names("komira_libc", "komira_metrics"), List[String](), _names("komira_log_holder")))
    n.append(LinkNode(String("komira_libc"), List[String](), _names("komira_libc_native"), List[String]()))
    n.append(LinkNode(String("komira_metrics"), List[String](), _names("komira_metrics_native"), List[String]()))
    n.append(LinkNode(String("plain"), _names("mojo-compiler"), List[String](), List[String]()))
    return n^


comptime RUN: String = "-Xlinker -L$CONDA_PREFIX/lib -Xlinker -lkomira_http_core_native -Xlinker -lkomira_async_native -Xlinker -lkomira_crypto_native -Xlinker -lkomira_libc_native -Xlinker -lkomira_metrics_native"
comptime BUILD_TAIL: String = " -Xlinker -lkomira_log_holder -Xlinker -rpath -Xlinker $ORIGIN/../lib"


def _joined(xs: List[String]) -> String:
    var s = String("")
    for i in range(len(xs)):
        if i > 0:
            s += String(" ")
        s += xs[i]
    return s^


def test_every_shared_library_dependents_first_then_the_static_archives_on_build() raises:
    var a = closure_link_args(_closure(), String("app"))
    # http_core reaches 5 shared libraries, async 3 (itself, libc, metrics
    # through log), the rest 1 each, in name order.
    assert_equal(_joined(a.run), String(RUN))
    assert_equal(_joined(a.build), String(RUN) + String(BUILD_TAIL))
    # a library inside the closure has its own, smaller closure
    var log = closure_link_args(_closure(), String("komira_log"))
    assert_equal(_joined(log.run), String("-Xlinker -L$CONDA_PREFIX/lib -Xlinker -lkomira_libc_native -Xlinker -lkomira_metrics_native"))
    # no native file: no arguments
    assert_true(closure_link_args(_closure(), String("plain")).is_empty())


def test_a_name_that_is_no_library_is_refused() raises:
    var why = String("")
    try:
        _ = closure_link_args(_closure(), String("komira_nothing"))
    except e:
        why = String(e)
    assert_equal(why, String("'komira_nothing' is not a library of the release set"))


def _readme_with(run: String, build: String) -> String:
    return (
        String("# app\n\n```mojo\nprint(1)\n```\n\n## Linking\n\n```sh komira-link\nmojo run ") + run
        + String(" prog.mojo\nmojo build ") + build + String(" prog.mojo -o $CONDA_PREFIX/bin/prog\n```\n")
    )


def _write(path: String, text: String) raises:
    var f = open(path, "w")
    f.write_bytes(text.as_bytes())
    f.close()


def _tool_args(name: String, text: String) raises -> LinkArgs:
    var tmp = test_tmpdir() + String("/") + name
    makedirs(tmp, exist_ok=True)
    _write(tmp + String("/README.md"), text)
    return readme_link_args_of(data_path(String("readme_examples")), tmp + String("/README.md"), String("src/app/README.md"), tmp)


comptime BUILD_QUOTED: String = " -Xlinker -lkomira_log_holder -Xlinker -rpath -Xlinker '$ORIGIN/../lib'"


def test_the_block_the_packer_writes_is_what_kci_computes() raises:
    var got = _tool_args(String("same"), _readme_with(String(RUN), String(RUN) + String(BUILD_QUOTED)))
    assert_equal(link_refusal(closure_link_args(_closure(), String("app")), got, String("share/doc/app/README.md")), String(""))
    # the README run is given the block's run arguments, the environment in
    # place of $CONDA_PREFIX
    var env = String("/scratch/v/work/.pixi/envs/default")
    var run = run_link_args(got, env)
    assert_equal(run[1], String("-L") + env + String("/lib"))
    var argv = run_program_argv(String("/scratch/v/work"), String("readme_app.mojo"), run)
    assert_equal(argv[5], String("run"))
    assert_equal(argv[6], String("-Xlinker"))
    assert_equal(argv[7], String("-L") + env + String("/lib"))
    assert_equal(argv[len(argv) - 1], String("/scratch/v/work/readme_app.mojo"))


def test_a_readme_without_an_owners_l_is_refused() raises:
    # The planted defect: the run line without -lkomira_metrics_native.
    var dropped = String(RUN).replace(String(" -Xlinker -lkomira_metrics_native"), String(""))
    assert_true(dropped != String(RUN))
    var got = _tool_args(String("dropped"), _readme_with(dropped, String(RUN) + String(BUILD_QUOTED)))
    assert_equal(
        link_refusal(closure_link_args(_closure(), String("app")), got, String("share/doc/app/README.md")),
        String("share/doc/app/README.md's link block says `mojo run ") + dropped
        + String("`; the package's closure needs `mojo run ") + String(RUN)
        + String("` (missing -lkomira_metrics_native)"),
    )
    # the build line is compared too: the holder's -l missing there
    var no_holder = _tool_args(String("no_holder"), _readme_with(String(RUN), String(RUN) + String(" -Xlinker -rpath -Xlinker '$ORIGIN/../lib'")))
    var why = link_refusal(closure_link_args(_closure(), String("app")), no_holder, String("R"))
    assert_true(why.startswith(String("R's link block says `mojo build ")), why)
    assert_true(why.endswith(String("(missing -lkomira_log_holder)")), why)
    # the same words in another order are refused too
    var swapped = String(RUN).replace(String("-lkomira_crypto_native -Xlinker -lkomira_libc_native"), String("-lkomira_libc_native -Xlinker -lkomira_crypto_native"))
    var reordered = _tool_args(String("reordered"), _readme_with(swapped, String(RUN) + String(BUILD_QUOTED)))
    assert_true(link_refusal(closure_link_args(_closure(), String("app")), reordered, String("R")).endswith(String("(the same words in another order)")))


def test_a_missing_block_and_an_unwanted_block_are_refused() raises:
    var none = _tool_args(String("none"), String("# app\n\n```mojo\nprint(1)\n```\n"))
    assert_true(none.is_empty())
    var why = link_refusal(closure_link_args(_closure(), String("app")), none, String("R"))
    assert_true(why.startswith(String("R holds no `sh komira-link` block, but the package's closure links native files")), why)
    var some = _tool_args(String("some"), _readme_with(String(RUN), String(RUN) + String(BUILD_QUOTED)))
    var why2 = link_refusal(closure_link_args(_closure(), String("plain")), some, String("R"))
    assert_true(why2.endswith(String("but the package's closure links no native file")), why2)
    # neither: nothing to say
    assert_equal(link_refusal(LinkArgs(), none, String("R")), String(""))


def test_a_block_the_tool_refuses_is_refused_in_its_words() raises:
    var why = String("")
    try:
        _ = _tool_args(String("bad"), String("# app\n\n```sh komira-link\nmojo run -lx;y prog.mojo\nmojo build p.mojo -o p\n```\n"))
    except e:
        why = String(e)
    assert_true(why.startswith(String("src/app/README.md:4: `;`")), why)


def test_the_tools_output_lines_are_read_back_strictly() raises:
    var a = parse_link_args(String("run\t-Xlinker\nbuild\t-lx\n"))
    assert_equal(len(a.run), 1)
    assert_equal(a.build[0], String("-lx"))
    var why = String("")
    try:
        _ = parse_link_args(String("walk\t-lx\n"))
    except e:
        why = String(e)
    assert_equal(why, String("the README examples tool's link output has the line 'walk\t-lx'"))


def test_the_readme_row_refuses_an_installed_readme_without_an_owners_l() raises:
    # installed_readme is the install validation's `readme` row: the planted
    # README fails it before anything runs.
    var tmp = test_tmpdir() + String("/installed")
    var env = tmp + String("/env")
    makedirs(env + String("/share/doc/app"), exist_ok=True)
    var dropped = String(RUN).replace(String(" -Xlinker -lkomira_metrics_native"), String(""))
    var readme = env + String("/share/doc/app/README.md")
    _write(readme, _readme_with(dropped, String(RUN) + String(BUILD_QUOTED)))
    var pin = InstallPin(String("app"))
    pin.is_library = True
    pin.import_name = String("app")
    pin.label = String("komira//src/app:app_conda")
    pin.has_doc_files = True
    pin.readme_sha256 = file_sha256_hex(readme)
    pin.link = closure_link_args(_closure(), String("app"))
    var why = String("")
    try:
        _ = installed_readme(pin, env, data_path(String("readme_examples")), tmp + String("/scratch"))
    except e:
        why = String(e)
    assert_true(why.startswith(String("share/doc/app/README.md's link block says `mojo run ")), why)
    assert_true(why.endswith(String("(missing -lkomira_metrics_native)")), why)
    # the README the packer writes passes the row, and its run arguments
    # name the environment
    _write(readme, _readme_with(String(RUN), String(RUN) + String(BUILD_QUOTED)))
    pin.readme_sha256 = file_sha256_hex(readme)
    var p = installed_readme(pin, env, data_path(String("readme_examples")), tmp + String("/scratch2"))
    assert_equal(len(p.run_args), 12)
    assert_equal(p.run_args[1], String("-L") + env + String("/lib"))
    assert_equal(p.run_args[11], String("-lkomira_metrics_native"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
