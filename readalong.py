"""Read Along executable entry point (thin shim).

The implementation lives in the ``readalong`` package. ``import readalong``
resolves to the package (a same-named package directory shadows this module, so
the public API always comes from ``readalong/__init__.py``).

This file is executed directly by the native backend
(``macapp/BackendService.swift`` runs ``readalong.py``) and by the README
(``python readalong.py ...``); it delegates to ``readalong.__main__.main``.
"""

from readalong.__main__ import main

if __name__ == "__main__":
    raise SystemExit(main())
