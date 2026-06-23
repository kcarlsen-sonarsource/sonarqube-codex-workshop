"""Task manager CLI — add, search, and export tasks."""

import sys
from database import init_db, add_task, search_tasks, export_tasks
from tasks import process_task_update


def print_tasks(tasks):
    if not tasks:
        print("No tasks found.")
        return
    for task_id, title, status, priority in tasks:
        print(f"  [{task_id}] {title} (status={status}, priority={priority})")


def handle_update():
    if len(sys.argv) < 5:
        print("Usage: python app.py update <id> <field> <value>")
        sys.exit(1)
    task = {"id": int(sys.argv[2]), "title": "", "status": "open", "priority": 0}
    updates = {sys.argv[3]: sys.argv[4]}
    result = process_task_update(task, updates, "member")
    if result["errors"]:
        print(f"Error: {result['errors'][0]}")
    elif result["changed"]:
        print(f"Task {task['id']} updated.")


def main():
    if len(sys.argv) < 2:
        print("Usage: python app.py <command> [args]")
        print("Commands: init, add, search, update, export")
        sys.exit(1)

    command = sys.argv[1]

    if command == "init":
        init_db()
        print("Database initialized.")

    elif command == "add":
        if len(sys.argv) < 3:
            print("Usage: python app.py add <title> [priority]")
            sys.exit(1)
        title = sys.argv[2]
        priority = int(sys.argv[3]) if len(sys.argv) > 3 else 0
        add_task(title, priority)
        print(f"Task added: {title}")

    elif command == "search":
        if len(sys.argv) < 3:
            print("Usage: python app.py search <query>")
            sys.exit(1)
        results = search_tasks(sys.argv[2])
        print_tasks(results)

    elif command == "update":
        handle_update()

    elif command == "export":
        status = sys.argv[2] if len(sys.argv) > 2 else "open"
        path = export_tasks(status)
        print(f"Exported to {path}")

    else:
        print(f"Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()
