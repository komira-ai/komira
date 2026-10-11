# =============================================================================
# komira_chat_store/erasure.mojo -- erasing one user, and the SQLite steps
#   that make the erasure reach the database file's bytes.
# =============================================================================
#
# `erase_user_rows` erases a user logically, on any backend:
#   * the bodies of the user's MESSAGE and EDIT events are overwritten with
#     the empty string in place, and their MESSAGE events are marked deleted
#     and lose their client_msg_id. The rows stay, so every channel's seqs
#     stay contiguous;
#   * the mention rows of the user's messages, and every mention row naming
#     the user, are deleted;
#   * the user's memberships, read cursors, file rows, user row and subject
#     row are deleted, the subject row last. The deleted file ids are
#     returned so the caller deletes their objects.
# The user's id stays where it is part of a row that is not the user's: the
# sender of the event rows (JOIN, LEAVE and the redacted MESSAGE and EDIT
# events), the mention list of other users' messages, and a channel's
# `created_by`, and a DM's channel id and `dm_user_ids`. No row maps that id
# to a person once the user and subject rows are gone. Running it again
# finds nothing left and returns zero counts; a run that stopped between the
# user row and the subject row is finished by running it again, by user id
# or by subject.
#
# ON SQLITE a deleted or overwritten value stays in the file's free space,
# and in the write-ahead log, unless the connection says otherwise:
#   * `prepare_sql_connection` turns on `PRAGMA secure_delete`, which makes
#     SQLite overwrite deleted content with zeros. It is a per-connection
#     setting: every connection a ChatStore uses must go through it.
#   * `finish_sql_erasure` runs `PRAGMA wal_checkpoint(TRUNCATE)`, which
#     copies the log into the database file and truncates the log to zero
#     bytes, so the old page images in it are gone.
# This covers the file contents, not the storage device beneath them. On
# Postgres both steps do nothing: a dead tuple stays readable until VACUUM,
# and backups keep data until they expire, so erasure there is logical. On a
# document store erasure is logical too: this package makes no claim about
# the bytes, point-in-time recovery or backups beneath it.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import Database, DbValue, Pred, SqlDatabase

from .ops import (
    all_of,
    chat_err,
    delete_all,
    eq,
    flag,
    i64,
    no_limit,
    no_order,
    select,
    set_to,
    sets,
    txt,
    update_all,
)
from .records import EraseCounts, EVENT_EDIT, EVENT_MESSAGE
from .schema import (
    T_CURSORS,
    T_EVENTS,
    T_FILES,
    T_MEMBERS,
    T_MENTIONS,
    T_SUBJECTS,
    T_USERS,
)


def erase_user_rows[
    RT: Runtime, DB: Database
](mut db: DB, mut reactor: Reactor[RT.Sink], user_id: String) raises -> EraseCounts:
    var rows_erased = 0
    var redacted = 0

    # The mention rows of the user's messages go with their bodies.
    var key_cols = List[String]()
    key_cols.append(String("channel_id"))
    key_cols.append(String("seq"))
    var mine = select[RT, DB](
        db,
        reactor,
        T_EVENTS,
        key_cols,
        all_of(
            eq("sender_user_id", txt(user_id)),
            eq("kind", i64(Int64(EVENT_MESSAGE))),
        ),
        no_order(),
        no_limit(),
    )
    for i in range(mine.__len__()):
        ref r = mine.row(i)
        rows_erased += delete_all[RT, DB](
            db,
            reactor,
            T_MENTIONS,
            all_of(
                eq("channel_id", txt(r.get_text(0))),
                eq("seq", i64(r.get_int8(1))),
            ),
        )

    redacted += update_all[RT, DB](
        db,
        reactor,
        T_EVENTS,
        all_of(
            eq("sender_user_id", txt(user_id)),
            eq("kind", i64(Int64(EVENT_MESSAGE))),
            eq("deleted", flag(False)),
        ),
        sets(
            set_to("body", txt(String())),
            set_to("deleted", flag(True)),
            set_to("client_msg_id", txt(String())),
        ),
    )
    _ = update_all[RT, DB](
        db,
        reactor,
        T_EVENTS,
        all_of(
            eq("sender_user_id", txt(user_id)),
            Pred.ne(String("client_msg_id"), txt(String())),
        ),
        sets(set_to("client_msg_id", txt(String()))),
    )
    redacted += update_all[RT, DB](
        db,
        reactor,
        T_EVENTS,
        all_of(
            eq("sender_user_id", txt(user_id)),
            eq("kind", i64(Int64(EVENT_EDIT))),
            Pred.ne(String("body"), txt(String())),
        ),
        sets(set_to("body", txt(String()))),
    )

    rows_erased += delete_all[RT, DB](
        db, reactor, T_MENTIONS, all_of(eq("user_id", txt(user_id)))
    )
    rows_erased += delete_all[RT, DB](
        db, reactor, T_MEMBERS, all_of(eq("user_id", txt(user_id)))
    )
    rows_erased += delete_all[RT, DB](
        db, reactor, T_CURSORS, all_of(eq("user_id", txt(user_id)))
    )

    var fcols = List[String]()
    fcols.append(String("file_id"))
    var files = select[RT, DB](
        db,
        reactor,
        T_FILES,
        fcols,
        all_of(eq("uploader_user_id", txt(user_id))),
        no_order(),
        no_limit(),
    )
    var file_ids = List[String]()
    for i in range(files.__len__()):
        file_ids.append(files.row(i).get_text(0))
    rows_erased += delete_all[RT, DB](
        db, reactor, T_FILES, all_of(eq("uploader_user_id", txt(user_id)))
    )

    # The user row first, then the subject row found by its user_id: a run
    # that stops between the two leaves the subject row (the subject key and
    # the user id), and a rerun by user id or by subject deletes it.
    rows_erased += delete_all[RT, DB](
        db, reactor, T_USERS, all_of(eq("user_id", txt(user_id)))
    )
    rows_erased += delete_all[RT, DB](
        db, reactor, T_SUBJECTS, all_of(eq("user_id", txt(user_id)))
    )
    return EraseCounts(rows_erased, redacted, file_ids^)


def user_ids_with_subject[
    RT: Runtime, DB: Database
](
    mut db: DB, mut reactor: Reactor[RT.Sink], iss: String, sub: String
) raises -> List[String]:
    """The ids of the user rows that hold (iss, sub). Two equalities need no
    composite index on a document store."""
    var cols = List[String]()
    cols.append(String("user_id"))
    var rows = select[RT, DB](
        db,
        reactor,
        T_USERS,
        cols,
        all_of(eq("iss", txt(iss)), eq("sub", txt(sub))),
        no_order(),
        no_limit(),
    )
    var out = List[String]()
    for i in range(rows.__len__()):
        out.append(rows.row(i).get_text(0))
    return out^


def prepare_sql_connection[
    RT: Runtime, DB: SqlDatabase
](mut db: DB, mut reactor: Reactor[RT.Sink]) raises:
    """Set up one SQL connection for the chat store. On SQLite, turn on
    `secure_delete` and check that it took; on another dialect, nothing."""
    if DB.dialect() != String("sqlite"):
        return
    var rows = db.query[RT](
        reactor, String("PRAGMA secure_delete=ON"), List[DbValue]()
    )
    if rows.__len__() != 1 or rows.row(0).get_int8(0) != 1:
        raise chat_err(String("PRAGMA secure_delete=ON did not take"))


def finish_sql_erasure[
    RT: Runtime, DB: SqlDatabase
](mut db: DB, mut reactor: Reactor[RT.Sink]) raises:
    """After an erasure on SQLite, move the write-ahead log into the database
    file and truncate it; raises if a reader kept the checkpoint from
    finishing. On another dialect, nothing."""
    if DB.dialect() != String("sqlite"):
        return
    var rows = db.query[RT](
        reactor, String("PRAGMA wal_checkpoint(TRUNCATE)"), List[DbValue]()
    )
    if rows.__len__() != 1 or rows.row(0).get_int8(0) != 0:
        raise chat_err(
            String("PRAGMA wal_checkpoint(TRUNCATE) was blocked; the erased")
            + String(" bytes may remain in the write-ahead log")
        )
