# =============================================================================
# orders_writer -- writes the table `orders` of the Iceberg scan conformance
# =============================================================================
#
# The program behind the `:orders_table` build action:
#
#   orders_writer --out-dir <dir>
#
# writes the table under `<dir>/orders` (komira_iceberg_test_tables,
# `write_orders_fixture`: its metadata, manifest lists, manifests, data files
# and delete files, recorded under file:///warehouse/db/orders). A refused
# write ends the program with an error, so the build action fails.

from std.sys import argv

from komira_iceberg_test_tables.orders_fixture import write_orders_fixture


def _flag(name: String) raises -> String:
    var args = argv()
    for i in range(1, len(args) - 1):
        if String(args[i]) == name:
            return String(args[i + 1])
    raise Error("orders_writer: missing " + name + " <value>")


def main() raises:
    _ = write_orders_fixture(_flag("--out-dir") + "/orders")
