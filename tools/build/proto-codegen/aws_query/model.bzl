"""The tiny awsQuery and ec2Query models this package generates clients from.

`model` is the label of a model file and `sha256` its digest, which
`aws-client-gen --model-sha256` requires. Each digest is stated once, here,
and read by both packages that generate from the model: this one (compiled
and tested) and the aws_codegen functional tests (the text goldens). An
edited model with a stale digest is refused by the generator.
"""

TINY_QUERY = struct(
    model = "komira//tools/build/proto-codegen/aws_query:tiny_query.json",
    sha256 = "87209ff5e3cb2615b200d1c96910de79bdce9ea0d87e8fd845e74b204a5bcd62",
)

TINY_EC2 = struct(
    model = "komira//tools/build/proto-codegen/aws_query:tiny_ec2.json",
    sha256 = "8b98402d5a3984adbcf0e94e153b7eed9e7afb0b278590ead57646b000560199",
)
