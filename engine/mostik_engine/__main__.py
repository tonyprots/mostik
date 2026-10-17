"""Точка входа: `python -m mostik_engine` (cwd или PYTHONPATH — каталог engine)."""
import os
import sys

from .privacy import OFFLINE_ENV, scrub_dev_overrides

# До импорта сервера: huggingface_hub читает HF_HUB_OFFLINE при импорте (приватность, п. 5).
os.environ.update(OFFLINE_ENV)
# В .app — без MOSTIK_MODELS_MANIFEST, TRANSCRIBER_UNPIN и других переопределений разработки (П10).
scrub_dev_overrides(os.environ)
# П10: всё, что создаёт движок (история, индекс, встречи, голоса), — только владельцу: 0600 и 0700.
os.umask(0o077)

from .server import main  # noqa: E402

sys.exit(main())
