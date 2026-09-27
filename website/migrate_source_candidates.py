"""Initialize the private candidate intake database before the site reload."""

from source_candidates import DATA, DATABASE, migrate

if __name__ == "__main__":
    migrate(DATA / DATABASE)
