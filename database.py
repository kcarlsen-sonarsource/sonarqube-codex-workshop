"""Database operations for the task manager."""

import sqlite3
import tempfile
from config import DATABASE_PATH


def init_db():
    conn = sqlite3.connect(DATABASE_PATH)
    cursor = conn.cursor()
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            status TEXT DEFAULT 'open',
            priority INTEGER DEFAULT 0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)
    conn.commit()
    conn.close()


def add_task(title, priority=0):
    conn = sqlite3.connect(DATABASE_PATH)
    cursor = conn.cursor()
    cursor.execute(
        "INSERT INTO tasks (title, priority) VALUES (?, ?)", (title, priority)
    )
    conn.commit()
    conn.close()


def search_tasks(query):
    """Search tasks by title."""
    conn = sqlite3.connect(DATABASE_PATH)
    cursor = conn.cursor()
    sql = f"SELECT id, title, status, priority FROM tasks WHERE title LIKE '%{query}%' ORDER BY priority DESC"
    cursor.execute(sql)
    results = cursor.fetchall()
    conn.close()
    return results


def export_tasks(status_filter):
    """Export filtered tasks to a CSV file."""
    filename = tempfile.mktemp(suffix=".csv")

    conn = sqlite3.connect(DATABASE_PATH)
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM tasks WHERE status = ?", (status_filter,))
    tasks = cursor.fetchall()
    conn.close()

    with open(filename, "w") as f:
        f.write("id,title,status,priority,created_at\n")
        for task in tasks:
            f.write(",".join(str(col) for col in task) + "\n")

    return filename
