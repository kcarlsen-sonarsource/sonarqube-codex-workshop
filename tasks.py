"""Task processing and validation logic."""


def process_task_update(task, updates, user_role):
    """Apply updates to a task with role-based permissions."""
    result = {"changed": False, "errors": []}

    for field, value in updates.items():
        if field == "status":
            if user_role == "admin":
                if value in ("open", "in_progress", "closed", "archived"):
                    if task["status"] == "archived":
                        if value == "closed":
                            result["errors"].append("Cannot close an archived task")
                        else:
                            task["status"] = value
                            result["changed"] = True
                    else:
                        task["status"] = value
                        result["changed"] = True
                else:
                    result["errors"].append(f"Invalid status: {value}")
            elif user_role == "member":
                if value in ("open", "in_progress", "closed"):
                    if task["status"] != "archived":
                        task["status"] = value
                        result["changed"] = True
                    else:
                        result["errors"].append("Cannot modify archived tasks")
                else:
                    result["errors"].append(f"Not allowed: {value}")
            else:
                result["errors"].append("Unknown role")
        elif field == "priority":
            if isinstance(value, int) and 0 <= value <= 5:
                task["priority"] = value
                result["changed"] = True
            else:
                result["errors"].append("Priority must be integer 0-5")
        elif field == "title":
            if value and len(value.strip()) > 0:
                task["title"] = value.strip()
                result["changed"] = True
            else:
                result["errors"].append("Title cannot be empty")

    return result
