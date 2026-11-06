"""Run the fermion CLI from the bundled interpreter (the .app has no console script)."""
import sys

from fermion.cli import main

sys.exit(main())
