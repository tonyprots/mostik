Mostik {{VERSION}} для macOS 14.2 и новее, Apple silicon.

## Установка одной командой

```bash
curl -fsSL https://tonyprots.github.io/mostik/install.sh | bash
```

Команда скачивает `.dmg` ниже, проверяет, что приложение подписано сертификатом «Mostik Release», ставит его в «Программы» и открывает. Окна «не удалось проверить разработчика» не будет. Можно попросить и агента: «Install Mostik: curl -fsSL https://tonyprots.github.io/mostik/install.sh | bash».

## Установка из .dmg

Mostik подписан собственным сертификатом проекта, а не сертификатом Apple Developer, поэтому при первом запуске из скачанного браузером `.dmg` macOS его остановит. Так нужно сделать один раз:

1. Откройте `.dmg` и перетащите Mostik в «Программы».
2. Запустите Mostik. macOS скажет, что не может проверить разработчика, — нажмите «Готово».
3. Откройте «Системные настройки → Конфиденциальность и безопасность», прокрутите до раздела «Безопасность» и нажмите «Всё равно открыть» рядом с Mostik. Подтвердите паролем или Touch ID.
4. Mostik откроется и попросит разрешения: микрофон, Универсальный доступ (вставка текста), для встреч — звук системы и «Запись экрана».

На macOS 15 Sequoia и новее открыть через Control-клик больше нельзя — только так, через Системные настройки.

## Обновления

Mostik раз в день проверяет, не вышла ли новая версия, и ставит её по вашей кнопке. Обновление скачивает сам Mostik, поэтому предупреждения macOS из шага 2 больше не будет, а разрешения сохранятся: все версии подписаны одним сертификатом.

---

**English.** Mostik {{VERSION}} for macOS 14.2+, Apple silicon. Install with one command: `curl -fsSL https://tonyprots.github.io/mostik/install.sh | bash` — it downloads the `.dmg` below, checks the app is signed by the “Mostik Release” certificate, installs it to Applications and opens it, with no Gatekeeper prompt. Or install by hand: Mostik is signed with the project’s own certificate, not an Apple Developer ID, so macOS blocks the first launch: open the `.dmg`, drag Mostik to Applications, launch it, click Done, then go to System Settings → Privacy & Security → Security and click “Open Anyway” next to Mostik. On macOS 15 Sequoia and later Control-click no longer works — use System Settings. Updates are checked once a day and installed when you click; they keep your permissions and don’t trigger the warning again.
