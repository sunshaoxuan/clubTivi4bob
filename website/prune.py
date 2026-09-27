"""Run daily to enforce diagnostic retention without relying on new uploads."""

import time

from app import _database, _prune
from source_registry import DATA, REPORT_DB, REPORT_TTL
from source_candidates import DATABASE as CANDIDATE_DB, prune as prune_candidates
import sqlite3

with _database() as connection:
    _prune(connection, int(time.time()))

with sqlite3.connect(DATA / REPORT_DB) as connection:
    connection.execute("DELETE FROM reports WHERE received <= ?", (int(time.time()) - REPORT_TTL,))
    connection.execute("DELETE FROM rate_limits WHERE window < ?", (int(time.time()) // 3600 - 1,))

with sqlite3.connect(DATA / CANDIDATE_DB) as connection:
    prune_candidates(connection, int(time.time()))
