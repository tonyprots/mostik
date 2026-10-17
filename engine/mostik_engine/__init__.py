"""Движок Mostik: потоковая диктовка поверх моделей transcriber."""

import sys as _sys

__version__ = "0.1.0"

# Внутри .app байткод уже собран (bundle.sh); запись __pycache__ в бандл ломала бы подпись.
if ".app/Contents/Resources/" in __file__:
    _sys.dont_write_bytecode = True

# движок из .app — окружение выпуска до любого другого импорта (PATH, кэш моделей, без
# переопределений разработки). Здесь, а не в точке входа: так и `mostik` (cli), и воркеры.
if ".app/Contents/" in __file__:
    import os as _os

    from .privacy import scrub_dev_overrides as _scrub

    _scrub(_os.environ)
