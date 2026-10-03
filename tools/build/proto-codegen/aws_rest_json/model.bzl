"""The tiny restJson1 model this package generates a client from.

`model` is the label of the model file and `sha256` its digest, which
`aws-client-gen --model-sha256` requires. The digest is stated once, here,
and read by both packages that generate from the model: this one (pure mode,
compiled and tested) and the aws_codegen functional tests (the client-mode
text golden). An edited model with a stale digest is refused by the generator.
"""

TINY_REST_JSON = struct(
    model = "komira//tools/build/proto-codegen/aws_rest_json:tiny_rest_json.json",
    sha256 = "75f8b51a5e483fb6c3d27804e6352092fb05a92536b730aa749d1923c838f1ee",
)
