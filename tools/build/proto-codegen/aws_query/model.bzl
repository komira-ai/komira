"""The tiny awsQuery model this package generates a client from.

`model` is the label of the model file and `sha256` its digest, which
`aws-client-gen --model-sha256` requires. The digest is stated once, here,
and read by both packages that generate from the model: this one (pure mode,
compiled and tested) and the aws_codegen functional tests (the pure-mode
text golden). An edited model with a stale digest is refused by the generator.
"""

TINY_QUERY = struct(
    model = "komira//tools/build/proto-codegen/aws_query:tiny_query.json",
    sha256 = "485983f34c7f0a2e52fd58adde6695c3b501269648b9c19e44f5113b04b14cf0",
)
