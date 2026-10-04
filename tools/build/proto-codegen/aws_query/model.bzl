"""The tiny awsQuery and ec2Query models this package generates clients from.

`model` is the label of a model file and `sha256` its digest, which
`aws-client-gen --model-sha256` requires. Each digest is stated once, here,
and read by both packages that generate from the model: this one (compiled
and tested) and the aws_codegen functional tests (the text goldens). An
edited model with a stale digest is refused by the generator.
"""

TINY_QUERY = struct(
    model = "komira//tools/build/proto-codegen/aws_query:tiny_query.json",
    sha256 = "485983f34c7f0a2e52fd58adde6695c3b501269648b9c19e44f5113b04b14cf0",
)

TINY_EC2 = struct(
    model = "komira//tools/build/proto-codegen/aws_query:tiny_ec2.json",
    sha256 = "8b98402d5a3984adbcf0e94e153b7eed9e7afb0b278590ead57646b000560199",
)
