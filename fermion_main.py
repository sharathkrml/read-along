"""Run the fermion CLI from the bundled interpreter (the .app has no console script)."""
import sys

import mlx.core as mx
from fermion.cli import main

# Live partials re-decode the whole in-flight segment every ~0.5 s and MLX keeps
# every freed Metal buffer by default; without a cap the server grows past 10 GB.
mx.set_cache_limit(768 << 20)
sys.exit(main())
