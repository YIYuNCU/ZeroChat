"""Transactional collection versions, including edits, deletes and retention."""
from contextlib import contextmanager


def install_revision(conn, table):
    if table not in {"short_term", "vector_embeddings"}:
        raise ValueError("Unsupported sync collection")
    conn.execute("CREATE TABLE IF NOT EXISTS sync_revisions (name TEXT PRIMARY KEY, version TEXT NOT NULL)")
    conn.execute("INSERT OR IGNORE INTO sync_revisions VALUES (?, lower(hex(randomblob(16))))", (table,))
    for operation in ("INSERT", "UPDATE", "DELETE"):
        conn.execute(f"""CREATE TRIGGER IF NOT EXISTS sync_{table}_{operation.lower()}
            AFTER {operation} ON {table} BEGIN
            UPDATE sync_revisions SET version = lower(hex(randomblob(16))) WHERE name = '{table}'; END""")
    conn.commit()


@contextmanager
def snapshot(conn, table):
    conn.execute("SAVEPOINT sync_page")
    try:
        yield conn.execute("SELECT version FROM sync_revisions WHERE name = ?", (table,)).fetchone()[0]
    finally:
        conn.execute("RELEASE SAVEPOINT sync_page")
