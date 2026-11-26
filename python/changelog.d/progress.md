- **Progress.** `Session.sql(query, progress=callback)` calls `callback(done, total)` on the calling
  thread with the plan segments the query has finished and the segments its plan has, each time that
  changes and once more when the query has answered. An exception the callback raises cancels the
  query and is raised from `sql`.
