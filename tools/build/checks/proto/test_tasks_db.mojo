from komira_db import DbRow, DbStorable, LOGICAL_UUID, SqlDatabase, Uuid
from std.testing import assert_equal, assert_true
from tasks_db.tasks_db import Task


struct Postgres(SqlDatabase):
    @staticmethod
    def placeholder(i: Int) -> String:
        return String("$") + String(i + 1)


def columns[T: DbStorable]() -> String:
    var out = String()
    for c in T.column_names():
        out += c + String(";")
    return out^


def main() raises:
    # The columns and statements follow tasks.proto, through the trait.
    assert_equal(columns[Task](), "id;owner;title;priority;done;")
    assert_equal(Task.column_types()[0].logical, LOGICAL_UUID)
    assert_true(Task.create_table_ddl().startswith("CREATE TABLE IF NOT EXISTS tasks ("))
    assert_equal(
        Task.insert_sql[Postgres](),
        "INSERT INTO tasks (id, owner, title, priority, done) VALUES ($1, $2, $3, $4, $5)",
    )
    # A row and back.
    var t = Task(
        id=Uuid(String("7f1c")),
        owner=String("ada"),
        title=String("ship"),
        priority=Int64(3),
        done=True,
    )
    var row = DbRow(t.to_row())
    var cols: List[Int] = [0, 1, 2, 3, 4]
    var u = Task.from_row(row, cols)
    assert_equal(u.id.text, "7f1c")
    assert_equal(u.owner, "ada")
    assert_equal(u.title, "ship")
    assert_equal(u.priority, Int64(3))
    assert_true(u.done)
    print("test_tasks_db: PASS")
