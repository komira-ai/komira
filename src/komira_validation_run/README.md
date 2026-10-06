# komira_validation_run

The tag/label key shape a validation run stamps on every billable cloud
resource it creates, so an unattended cleanup can act only on resources it can
prove its own run made. A key is `<prefix>-<suffix>`: the caller chooses the
prefix, and the two fixed suffixes are `run-id` (the id of the run that created
the resource) and `retention` (the authored retention of the node that made
it, `delete` or `retain`). Keys and run ids are checked against the
intersection of the AWS tag rules and the GCP label rules (lowercase letters,
digits, `-` and `_`, at most 63 bytes), so one spelling is legal verbatim on
both clouds. The package has no dependencies.

## Examples

Build the two keys from one prefix; a prefix one of the clouds would reject
raises:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_validation_run.validation_run_tag import is_valid_tag_key_prefix, resource_retention_tag_key, validation_run_tag_key

assert_equal(validation_run_tag_key("acme"), "acme-run-id")
assert_equal(resource_retention_tag_key("acme"), "acme-retention")
assert_false(is_valid_tag_key_prefix("Acme"))

var refused = False
try:
    _ = validation_run_tag_key("my.tool")
except:
    refused = True
assert_true(refused)
```

Check a run id before stamping it: empty, uppercase and over-length ids are
refused:

<!-- mojo-hidden from std.testing import assert_false, assert_true -->
```mojo
from komira_validation_run.validation_run_tag import VALIDATION_RUN_ID_MAX_LEN, is_valid_validation_run_id

assert_true(is_valid_validation_run_id("run-20261006-a1b2"))
assert_false(is_valid_validation_run_id(""))
assert_false(is_valid_validation_run_id("Run-1"))
assert_false(is_valid_validation_run_id(String("a") * (VALIDATION_RUN_ID_MAX_LEN + 1)))
```

Project a manifest `Retention` ordinal onto the retention mark; an unknown
ordinal raises instead of picking a side:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_validation_run.validation_run_tag import is_valid_retention_tag_value, retention_tag_value

assert_equal(retention_tag_value(0), "delete")
assert_equal(retention_tag_value(1), "delete")
assert_equal(retention_tag_value(2), "retain")
assert_true(is_valid_retention_tag_value("retain"))
assert_false(is_valid_retention_tag_value("keep"))

var raised = False
try:
    _ = retention_tag_value(3)
except:
    raised = True
assert_true(raised)
```
