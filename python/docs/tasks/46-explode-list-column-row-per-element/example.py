from pathlib import Path

import pyarrow.parquet as pq

import komira

Path("posts.csv").write_text("id,tags\n1,red;blue\n2,green\n3,blue;green;yellow\n")

with komira.Session() as s:
    s.register_csv("posts", "posts.csv")
    # SQL: unnest(list) as a SELECT item gives one row per element, the other
    # items repeated. string_split makes the list.
    sql = (
        "SELECT id, unnest(string_split(tags, ';')) AS tag"
        " FROM posts ORDER BY id, tag"
    )
    for row in s.sql(sql).to_arrow().to_pylist():
        print(row)
    # The same lists as a column, kept in a Parquet file for the frame below.
    lists = s.sql("SELECT id, string_split(tags, ';') AS tags FROM posts")
    pq.write_table(lists.to_arrow(), "posts.parquet")

# pandas-shaped: explode replaces the list column by its elements.
df = komira.read_parquet("posts.parquet").explode("tags")
print(df.sort_values(["id", "tags"]).materialize().to_arrow().to_pylist())
