"""Bounded inbox recovery and retention; never depends on a desktop client."""
import json
import os
from pathlib import Path
import time

from catalog_event_queue import drain
from diagnostic_store import DiagnosticStore


def main():
    root = Path(os.environ.get('BOBTV_DATA_DIR', Path(__file__).parent / 'data'))
    DiagnosticStore(Path(os.environ.get('BOBTV_DIAGNOSTICS_DIR', root / 'diagnostics-v2'))).prune()
    print(json.dumps(drain(root)))


if __name__ == '__main__':
    main()
