# The routes module protoc-gen-mojo-routes writes for
# example/library/v1/library_service.proto, held byte for byte to
# golden/library_service_routes.mojo.golden. A change to the emitter's output
# fails here, naming the first line that differs; the golden is rewritten in
# the same change (see BUCK).

from std.testing import assert_equal

from komira_runtime_paths import read_data


def test_generated_module_matches_golden() raises:
    var got = read_data(String("gen/library_service_routes.mojo"))
    var want = read_data(String("golden/library_service_routes.mojo.golden"))
    if got == want:
        return
    var g = got.split("\n")
    var w = want.split("\n")
    var n = min(len(g), len(w))
    for i in range(n):
        if String(g[i]) != String(w[i]):
            raise Error(
                String("generated line ")
                + String(i + 1)
                + String(" differs from the golden:\n  generated: ")
                + String(g[i])
                + String("\n  golden:    ")
                + String(w[i])
            )
    assert_equal(len(g), len(w), "the generated module and the golden differ in length")


def main() raises:
    test_generated_module_matches_golden()
    print("PASS test_routes_golden")
