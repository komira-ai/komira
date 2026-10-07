# kci_params

Declared app parameters, with no dependencies. An app declares the parameters
it takes as a list of `AppParamDecl` (a flag name, an obligation: required,
runner-injected or optional, a kind: literal, reference or secret reference,
a default and a description). `render_app_params` turns that declaration and
the supplied `AppParamValue`s into `--<name>=<value>` command-line arguments,
and `parse_app_params` reads them back at the app's startup against the same
declaration, into an `AppParamBinding`. Both ends refuse, with an error naming
the parameter, a missing required parameter, an undeclared one and an empty
value; the renderer also refuses a literal supplied for a reference or
secret-reference parameter (a secret parameter carries the secret's resource
name, never its value), and the parser a repeated flag. For a
store that must not know any app's parameters, `encode_app_param_config_value`
and `collect_app_params_from_config` carry the values as opaque
`APP_PARAM:<name>` config entries, and `render_app_param_argv` renders them
without the declaration. The package is pure computation over strings.

## Examples

Declare, render and parse back:

<!-- mojo-hidden from std.testing import assert_equal, assert_false -->
```mojo
from kci_params import AppParamDecl, AppParamValue, PARAM_REQUIRED, PARAM_OPTIONAL
from kci_params import PARAM_KIND_LITERAL, literal_param, render_app_params
from kci_params import parse_app_params

var decls = List[AppParamDecl]()
decls.append(AppParamDecl("port", PARAM_REQUIRED, PARAM_KIND_LITERAL, "", "Port to listen on."))
decls.append(AppParamDecl("batch", PARAM_OPTIONAL, PARAM_KIND_LITERAL, "100", "Rows per flush."))
decls.append(AppParamDecl("label", PARAM_OPTIONAL, PARAM_KIND_LITERAL, "", "Display label."))

var values = List[AppParamValue]()
values.append(literal_param("port", "8080"))
var argv = render_app_params("demo", decls, values)
# The optional with a default is rendered; the one without is omitted.
assert_equal(len(argv), 2)
assert_equal(argv[0], "--port=8080")
assert_equal(argv[1], "--batch=100")

var process_argv = List[String]()
process_argv.append("demo")
for i in range(len(argv)):
    process_argv.append(argv[i])
var bound = parse_app_params("demo", decls, process_argv)
assert_equal(bound.get("port"), "8080")
assert_equal(bound.get("batch"), "100")
assert_false(bound.has("label"))
```

A missing required parameter is refused at render time, naming it:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from kci_params import AppParamDecl, AppParamValue, PARAM_REQUIRED, PARAM_KIND_LITERAL, render_app_params

var required = List[AppParamDecl]()
required.append(AppParamDecl("port", PARAM_REQUIRED, PARAM_KIND_LITERAL, "", "Port to listen on."))
var message = String()
try:
    _ = render_app_params("demo", required, List[AppParamValue]())
except e:
    message = String(e)
assert_true(message.find("NO GAP VIOLATED") >= 0)
assert_true(message.find("'port'") >= 0)
```

A secret parameter takes a reference; a literal for it is refused:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from kci_params import AppParamDecl, AppParamValue, PARAM_RUNNER_INJECTED
from kci_params import PARAM_KIND_SECRET_REFERENCE, literal_param
from kci_params import secret_reference_param, render_app_params

var secret_decls = List[AppParamDecl]()
secret_decls.append(
    AppParamDecl("signing-key", PARAM_RUNNER_INJECTED, PARAM_KIND_SECRET_REFERENCE, "", "Signing key.")
)
var ref_values = List[AppParamValue]()
ref_values.append(secret_reference_param("signing-key", "projects/p/secrets/key/versions/latest"))
var rendered = render_app_params("demo", secret_decls, ref_values)
assert_equal(rendered[0], "--signing-key=projects/p/secrets/key/versions/latest")

var leaked = List[AppParamValue]()
leaked.append(literal_param("signing-key", "not-a-reference"))
var refusal = String()
try:
    _ = render_app_params("demo", secret_decls, leaked)
except e:
    refusal = String(e)
assert_true(refusal.find("NO LEAK VIOLATED") >= 0)
```

Carry parameters as opaque config entries and render them without the
declaration (the entries come back sorted by name):

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_params import PARAM_KIND_LITERAL, PARAM_KIND_REFERENCE, app_param_config_key
from kci_params import encode_app_param_config_value, collect_app_params_from_config
from kci_params import render_app_param_argv

var keys = List[String]()
var raws = List[String]()
keys.append(app_param_config_key("store"))
raws.append(encode_app_param_config_value(PARAM_KIND_REFERENCE, "s3://bucket/app"))
keys.append("UNRELATED")
raws.append("ignored")
keys.append(app_param_config_key("batch"))
raws.append(encode_app_param_config_value(PARAM_KIND_LITERAL, "100"))
assert_equal(keys[0], "APP_PARAM:store")
assert_equal(raws[0], "1|s3://bucket/app")

var collected = collect_app_params_from_config(keys, raws)
assert_equal(len(collected), 2)
var store_argv = render_app_param_argv(collected)
assert_equal(store_argv[0], "--batch=100")
assert_equal(store_argv[1], "--store=s3://bucket/app")
```
