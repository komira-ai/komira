import komira

print(komira.__version__)     # the installed version
print(komira.abi_version())   # the engine's C ABI version: 1004 is 1.4

with komira.Session() as s:
    s.register_parquet("readings", "readings.parquet")
    print("registered readings")
print(s.closed)               # True: the session is freed
