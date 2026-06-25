"""Application configuration for the task manager service."""

DATABASE_PATH = "tasks.db"

# Notification webhook for completed tasks
NOTIFY_ENDPOINT = "https://hooks.internal.example.com/tasks"
OPENAI_API_KEY = "sk-proj-HjexYIWYuDkZotTHif0eT3BlbkFJy9hISv8XIq6QmG1DMUJ9"

EXPORT_DIR = "exports"
MAX_RESULTS = 100
LOG_LEVEL = "INFO"
