"""python -m avaya_ossi → long-lived session CLI."""

from __future__ import annotations

import sys

from avaya_ossi.cli import main

if __name__ == "__main__":
    sys.exit(main())
