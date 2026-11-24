import pyarrow as pa
import pyarrow.parquet as pq

import komira

print(komira.__version__)     # the installed version
print(komira.abi_version())   # the engine's C ABI version: 1004 is 1.4

# A small Parquet file to query: six days of weather in three cities.
weather = pa.table({
    "city": ["Oslo", "Lima", "Oslo", "Pune", "Lima", "Oslo"],
    "temp": [3, 18, 1, 31, 20, 5],
    "rain": [1.5, 0.0, 2.5, 4.0, 0.5, 1.0],
})
pq.write_table(weather, "weather.parquet")

with komira.Session() as s:
    s.register_parquet("weather", "weather.parquet")

    # An answer is a pyarrow Table; to_pylist() gives its rows.
    total = s.sql("SELECT count(*) AS days, sum(rain) AS rain FROM weather")
    print(total.to_arrow().to_pylist())

    # A group-by with an aggregate and an order.
    table = s.sql(
        "SELECT city, count(*) AS days, avg(temp) AS mean, max(temp) AS hottest"
        " FROM weather GROUP BY city ORDER BY city"
    ).to_arrow()
    print(table.schema)
    for row in table.to_pylist():
        print(row)

    # Batch by batch with to_reader(), or by any Arrow library.
    hot = "SELECT city, temp FROM weather WHERE temp > 10 ORDER BY temp DESC"
    print(s.sql(hot).to_reader().read_all().to_pylist())
    print(pa.table(s.sql(hot)).column("city").to_pylist())

    # A mistake raises komira.KomiraError, naming the file or the place.
    try:
        s.register_parquet("missing", "no_such_file.parquet")
    except komira.KomiraError as e:
        print(e)
    try:
        s.sql("SELECT city, count(*) FROM weather GROUP city")
    except komira.KomiraError as e:
        print(e)
print(s.closed)               # True: the session is freed
