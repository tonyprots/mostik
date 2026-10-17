import Foundation
import MostikCore

/// П8, пункт 5: строки манифеста из ответа движка, что обязательно для языка, тексты ошибок, событие хода.
func runModelCatalogTests() {
    func row(_ key: String, _ purpose: String, required: Bool = true, installed: Bool = false,
             size: Double = 1_000_000_000, missing: Double = 1_000_000_000) -> JSONValue {
        .object(["key": .string(key), "label": .string(key.uppercased()), "purpose": .string(purpose),
                 "required": .bool(required), "installed": .bool(installed), "size": .number(size),
                 "missing_bytes": .number(missing), "partial_bytes": .number(size - missing)])
    }
    let payload: [String: JSONValue] = ["models": .array([
        row("vad", "vad", installed: true, size: 2_000_000, missing: 0),
        row("gigaam", "ru", size: 890_000_000, missing: 400_000_000),
        row("whisper", "en", size: 1_620_000_000, missing: 1_620_000_000),
        row("gemma", "llm", required: false),
        .string("мусор"),
    ])]
    let rows = ModelCatalog.rows(from: payload)
    equal(rows.map(\.key), ["vad", "gigaam", "whisper", "gemma"], "мусор пропущен")
    equal(rows[1].partialBytes, 490_000_000, "докачка видна")
    equal(ModelCatalog.missing(rows, language: "ru").map(\.key), ["gigaam"], "для русского — только GigaAM")
    equal(ModelCatalog.missing(rows, language: "en").map(\.key), ["whisper"], "для английского — Whisper")
    check(!rows[3].neededFor(language: "ru"), "LLM по желанию")
    equal(ModelCatalog.bytesToDownload(ModelCatalog.missing(rows, language: "ru")), 400_000_000, "качаем только остаток")
    equal(ModelCatalog.size(1_620_000_000, russian: true), "1,6 ГБ")
    equal(ModelCatalog.size(1_620_000_000, russian: false), "1.6 GB")
    equal(ModelCatalog.size(2_300_000, russian: true), "2 МБ")
    equal(ModelCatalog.rows(from: [:]), [], "старый движок без models")

    check(ModelCatalog.errorText(code: "models_network", message: "x", russian: true).contains("продолжится"), "сеть")
    check(ModelCatalog.errorText(code: "models_checksum", message: "", russian: false).contains("damaged"), "сумма")
    equal(ModelCatalog.errorText(code: "other", message: "как есть", russian: true), "как есть")

    let line = #"{"event": "models_progress", "key": "whisper", "file": "model.safetensors", "done": 3000000000, "total": 3550000000}"#
    equal(EngineCodec.decode(line: line),
          .progress(task: "models:whisper", stage: "model.safetensors", done: 3_000_000_000, total: 3_550_000_000),
          "событие хода загрузки, байты больше 2^31")
    let p = ModelProgress(key: "k", done: 50, total: 200)
    equal(p.fraction, 0.25)
    equal(ModelProgress(key: "k", done: 5, total: 0).fraction, 0, "без total — ноль, не деление на ноль")

    runModelQueueTests(rows)
}

/// модели распознавания не ждут LLM, вторая «Скачать» не теряется.
private func runModelQueueTests(_ rows: [ModelRow]) {
    let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
    let diar = ModelRow(key: "diar", label: "D", purpose: "diarization", required: false, size: 34_000_000, installed: false)
    func priority(_ key: String) -> Int { ModelDownloadQueue.priority(key == "diar" ? diar : byKey[key]) }

    var q = ModelDownloadQueue()
    equal(q.request(["gemma"], priority: priority), .start(["gemma"]), "свободно — сразу")
    equal(q.request(["gigaam", "vad"], priority: priority), .cancelRunning, "распознавание вытесняет LLM")
    equal(q.pending, ["gigaam", "vad", "gemma"], "LLM — после, порядок запроса сохранён")
    equal(q.request(["whisper"], priority: priority), .wait, "второе вытеснение не нужно — уже останавливаем")
    equal(q.failed(cancelled: true), ["gigaam", "vad", "whisper", "gemma"], "остановка ради важной — не ошибка, едем дальше")
    equal(q.finished(), nil, "очередь пуста")
    check(!q.busy)

    var low = ModelDownloadQueue()
    _ = low.request(["gigaam"], priority: priority)
    equal(low.request(["gemma"], priority: priority), .wait, "LLM ждёт распознавание, не вытесняет")
    equal(low.request(["gemma", "gigaam"], priority: priority), .wait, "повторное нажатие не дублирует")
    equal(low.pending, ["gemma"])
    equal(low.request(["diar"], priority: priority), .wait)
    equal(low.pending, ["diar", "gemma"], "голоса раньше LLM")
    equal(low.finished(), ["diar", "gemma"])

    var net = ModelDownloadQueue()
    _ = net.request(["gemma"], priority: priority)
    _ = net.request(["gigaam"], priority: priority)
    equal(net.failed(cancelled: false), nil, "нет сети посреди вытеснения — стоп, без бесконечных повторов")
    check(net.pending.isEmpty && !net.busy)

    var user = ModelDownloadQueue()
    _ = user.request(["gigaam"], priority: priority)
    _ = user.request(["gemma"], priority: priority)
    user.userCancelled()
    equal(user.failed(cancelled: true), nil, "«Остановить» человеком очередь не продолжает")
}

