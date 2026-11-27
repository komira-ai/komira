import { writeFileSync } from "node:fs";

import * as km from "@komira-ai/komira";

console.log(km.version); // the installed version
console.log(km.abiVersion()); // the engine's C ABI version: 1009 is 1.9

// Six days of weather in three cities, as a CSV file.
writeFileSync(
  "weather.csv",
  "city,temp,rain\nOslo,3,1.5\nLima,18,0.0\nOslo,1,2.5\nPune,31,4.0\nLima,20,0.5\nOslo,5,1.0\n",
);

const s = new km.Session();
try {
  // COPY writes it as the Parquet file to query and answers the rows it wrote.
  const copied = await s.sql("COPY (SELECT * FROM read_csv('weather.csv')) TO 'weather.parquet'");
  console.log((await copied.toArrow()).toArray().map((row) => row.toJSON()));
  await s.registerParquet("weather", "weather.parquet");

  // An answer is an apache-arrow Table; a BIGINT reads as a JavaScript bigint.
  const total = await s.sql("SELECT count(*) AS days, sum(rain) AS rain FROM weather");
  console.log((await total.toArrow()).toArray().map((row) => row.toJSON()));

  // A group-by with an aggregate and an order, and the answer's schema.
  const grouped = await s.sql(
    "SELECT city, count(*) AS days, avg(temp) AS mean, max(temp) AS hottest" +
      " FROM weather GROUP BY city ORDER BY city",
  );
  const table = await grouped.toArrow();
  for (const field of table.schema.fields) {
    console.log(`${field.name}: ${field.type}${field.nullable ? "" : " not null"}`);
  }
  for (const row of table) {
    console.log(row.toJSON());
  }

  // Batch by batch, with for await.
  const hot = await s.sql("SELECT city, temp FROM weather WHERE temp > 10 ORDER BY temp DESC");
  const cities = [];
  for await (const batch of hot) {
    cities.push(...batch.getChild("city"));
  }
  console.log(cities);

  // A mistake rejects with a km.KomiraError, naming the file or the place.
  try {
    await s.registerParquet("missing", "no_such_file.parquet");
  } catch (e) {
    if (!(e instanceof km.KomiraError)) throw e;
    console.log(e.message);
  }
  try {
    await s.sql("SELECT city, count(*) FROM weather GROUP city");
  } catch (e) {
    if (!(e instanceof km.KomiraError)) throw e;
    console.log(e.message);
  }
} finally {
  s.close();
}
console.log(s.closed); // true: the session is freed
