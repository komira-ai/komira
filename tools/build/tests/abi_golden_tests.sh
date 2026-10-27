# shellcheck shell=bash
# abi_golden_tests.sh -- tests of komira_abi_golden (tools/build/mojo/abi_golden.bzl).
# Sourced by tools/build/tests/run_tests.sh (uses its expect_green and
# expect_red); not run on its own.
#
#  55. The ABI golden and the C header: the example (a golden checked against
#      its Mojo source, a C driver that includes the generated header and
#      defines each function it declares, and the shared library of the same
#      source) and tests//functional/abi_golden:ok build; each target of
#      tests//negative/abi_golden fails naming its one defect: a changed return
#      type, a symbol the source no longer exports, a symbol the golden does
#      not list, a type outside the type map, and a row whose `since` is above
#      the golden version.

# 55
E=//tools/build/examples/abi_golden
expect_green abi_golden_example "$E:abi_header" "$E:header_driver" "$E:abi_lib"
expect_green abi_golden_ok tests//functional/abi_golden:ok
N=tests//negative/abi_golden
for want in \
    "drift|\`neg_add\`: the return type changed: golden \`Int64\`, source \`Int32\`" \
    "removed|missing symbol \`neg_fill\`" \
    "added|extra symbol \`neg_extra\`" \
    "unknown_type|the argument type \`Bool\` is not in the type map" \
    "since_above_version|\`neg_fill\`: since 1.2 is above the golden version 1.1"; do
    expect_red "abi_golden_${want%%|*}" "${want#*|}" "$N:${want%%|*}"
done
