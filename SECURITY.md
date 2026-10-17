# Безопасность / Security

## Как сообщить об уязвимости

Пожалуйста, не публикуйте уязвимость в открытых задачах. Напишите сопровождающим закрыто:

- **Адрес для сообщений:** появится до первого публичного выпуска. Пока его нет, откройте задачу в репозитории с заголовком «Security: прошу закрытый канал» без подробностей — с вами свяжутся.

Что приложить: версию Mostik и macOS, шаги воспроизведения, что именно можно получить или сломать. Мы подтвердим получение в течение 7 дней и договоримся о сроке исправления до раскрытия.

## Что входит

- Приложение Mostik (Swift) и движок `engine/` (Python), включая CLI `mostik` и MCP-сервер.
- Установка хуков и скилла агентам (Claude Code, Codex): что и куда пишется в их настройки.
- Внешний календарь-команда ([docs/external-calendar.md](docs/external-calendar.md)): проверка файла, подтверждение пути, окружение, таймаут и потолок вывода.
- Автообновление (Sparkle): подпись EdDSA и лента обновлений.

Особенно важно: текст из буфера или полей, ушедший туда, куда пользователь не соглашался; вставка в поле пароля; выполнение команд из расшифровки или из файлов проекта (защита от инъекции в причёсывании и командах-намерениях); запись без индикатора.

## Поддерживаемые версии

Исправления выходят для последней версии. Старые версии обновляются через автообновление.

---

## Reporting a vulnerability

Please do not file vulnerabilities as public issues. Contact the maintainers privately:

- **Security contact:** will be published before the first public release. Until then, open an issue titled "Security: requesting a private channel" with no details, and a maintainer will reach out.

Include the Mostik and macOS versions, steps to reproduce, and the impact. We acknowledge reports within 7 days and agree on a fix timeline before disclosure.

In scope: the Mostik app (Swift), the Python engine in `engine/` including the `mostik` CLI and MCP server, agent hook and skill installation, and Sparkle updates (EdDSA signing, appcast). Of particular interest: text leaving the Mac without consent, typing into password fields, executing commands from transcripts or project files (prompt injection in polishing and voice intents), and recording without a visible indicator.

Only the latest version receives fixes.
