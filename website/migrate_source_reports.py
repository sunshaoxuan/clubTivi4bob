"""Apply the versioned source report schema before enabling the API."""

from source_registry import DATA, REPORT_DB, migrate

if __name__ == "__main__":
    migrate(DATA / REPORT_DB)
