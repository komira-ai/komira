import komira

print(komira.__version__)     # the installed version
print(komira.abi_version())   # the engine's C ABI version: 1005 is 1.5

with komira.Session() as s:
    s.register_parquet("readings", "readings.parquet")
    print(s.sql("SELECT 1 AS n").to_arrow().to_pylist())
    result = s.sql("SELECT count(*) AS n, sum(value) AS total FROM readings")
    print(result.to_arrow().to_pylist())   # a pyarrow Table, as Python rows
print(s.closed)               # True: the session is freed
