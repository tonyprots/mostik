import SwiftUI
import MostikCore

/// Тонкая полоса хода загрузки — своя, без системного ProgressView: ровно по токенам палитры.
struct ModelBar: View {
    var fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.sunken)
                Capsule().fill(Palette.accent).frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel(L("Загрузка", "Download"))
        .accessibilityValue("\(Int((fraction * 100).rounded()))%")
    }
}

/// Группа «Модели» в Настройках (П8, пункт 5): строка на модель, размер, статус, ход загрузки.
struct ModelsSection: View {
    @ObservedObject var models: ModelsModel

    var body: some View {
        FormGroup(title: L("Модели", "Models"), accessory: AnyView(actions)) {
            if !models.known {
                FormNote(text: L("Движок ещё не ответил.", "The engine hasn’t answered yet."))
            }
            ForEach(Array(models.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { FormDivider() }
                line(row)
            }
            if let error = models.error {
                FormDivider()
                Text(error).font(TType.callout).foregroundStyle(Palette.record)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, DS.Space.s)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if models.downloading {
            Button(L("Остановить", "Pause")) { models.cancel() }
                .buttonStyle(.mostik(.secondary, compact: true))
        } else if !models.missing.isEmpty {
            Button(L("Скачать нужные · ", "Download required · ")
                   + ModelCatalog.size(ModelCatalog.bytesToDownload(models.missing), russian: L10n.isRussian)) {
                models.start(models.missing.map(\.key))
            }
            .buttonStyle(.mostik(.primary, compact: true))
        }
    }

    private func line(_ row: ModelRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FormRow(title: row.label,
                    hint: purpose(row) + " · " + ModelCatalog.size(row.size, russian: L10n.isRussian)) {
                status(row)
            }
            if let p = models.progress[row.key], !row.installed {
                ModelBar(fraction: p.fraction).padding(.bottom, DS.Space.s)
            }
        }
    }

    @ViewBuilder private func status(_ row: ModelRow) -> some View {
        if row.installed {
            HStack(spacing: 6) {
                StatusDot(color: Palette.accent)
                Text(L("Установлена", "Installed")).font(TType.body).foregroundStyle(Palette.inkSecondary)
            }
        } else if let p = models.progress[row.key] {
            Text(ModelCatalog.size(p.done, russian: L10n.isRussian) + L(" из ", " of ")
                 + ModelCatalog.size(p.total, russian: L10n.isRussian))
                .font(TType.body.monospacedDigit()).foregroundStyle(Palette.inkSecondary)
        } else {
            HStack(spacing: DS.Space.xs) {
                if row.partialBytes > 0 {
                    Text(L("скачано ", "downloaded ") + ModelCatalog.size(row.partialBytes, russian: L10n.isRussian))
                        .font(TType.callout).foregroundStyle(Palette.inkTertiary)
                }
                if models.scheduled(row.key) {
                    Text(L("в очереди", "queued")).font(TType.callout).foregroundStyle(Palette.inkTertiary)
                } else {
                    // Во время другой загрузки — в очередь, а не «ничего не происходит».
                    Button(L("Скачать", "Download")) { models.start([row.key]) }
                        .buttonStyle(.mostik(.secondary, compact: true))
                }
            }
        }
    }

    private func purpose(_ row: ModelRow) -> String {
        switch row.purpose {
        case "vad": return L("Отличает речь от тишины, нужна всегда", "Tells speech from silence, always needed")
        case "ru": return L("Русская диктовка", "Russian dictation")
        case "en": return L("Английская диктовка", "English dictation")
        case "verifier-en": return L("Второе распознавание английских терминов, по желанию", "Second pass for English terms, optional")
        case "llm": return L("Причёсывание на этом Mac, по желанию", "On-device text polish, optional")
        case "diarization": return L("Разделение встречи по голосам", "Splits a meeting by speaker")
        default: return row.required ? L("Обязательная", "Required") : L("По желанию", "Optional")
        }
    }
}

/// Карточка первого запуска «Нужны модели» (П8, пункт 5): без сети приложение не падает,
/// а говорит, чего не хватает, сколько это весит и как поставить.
struct ModelsNeededCard: View {
    @ObservedObject var models: ModelsModel
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(L("Нужны модели распознавания", "Speech models needed"))
                .font(TType.headline).foregroundStyle(Palette.ink)
            Text(L("Mostik распознаёт речь на этом Mac, без облака. Для этого один раз нужно скачать ",
                   "Mostik recognizes speech on this Mac, with no cloud. It needs a one-time download of ")
                 + models.missing.map(\.label).joined(separator: ", ")
                 + " — " + ModelCatalog.size(ModelCatalog.bytesToDownload(models.missing), russian: L10n.isRussian)
                 + ".")  // про кэш Hugging Face не пишем: на чистом Mac его нет
                .font(TType.body).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if models.downloadingNeeded {
                ModelBar(fraction: overall)
                Text(L("Можно закрыть окно — загрузка продолжится.", "You can close this window — the download continues."))
                    .font(TType.callout).foregroundStyle(Palette.inkTertiary)
            }
            if let error = models.error {
                Text(error).font(TType.callout).foregroundStyle(Palette.record)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.xs) {
                if models.downloadingNeeded {
                    Button(L("Остановить", "Pause")) { models.cancel() }
                        .buttonStyle(.mostik(.secondary))
                } else {
                    // Идёт загрузка LLM — модели распознавания вытеснят её и пойдут первыми.
                    Button(L("Скачать", "Download")) { models.start(models.missing.map(\.key)) }
                        .buttonStyle(.mostik(.primary))
                }
                Button(L("Подробнее в Настройках", "Details in Settings")) { onOpenSettings() }
                    .buttonStyle(.mostik(.quiet))
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.edgeStrong))
    }

    private var overall: Double {
        let total = models.missing.reduce(Int64(0)) { $0 + $1.size }
        guard total > 0 else { return 0 }
        let done = models.missing.reduce(Int64(0)) { sum, row in
            sum + (models.progress[row.key]?.done ?? (row.size - row.missingBytes))
        }
        return min(1, Double(done) / Double(total))
    }
}

/// Полоса над вкладками: карточка «Нужны модели», пока обязательных моделей нет.
struct ModelsGate: View {
    @ObservedObject var models: ModelsModel
    var onOpenSettings: () -> Void

    var body: some View {
        if models.needed {
            ModelsNeededCard(models: models, onOpenSettings: onOpenSettings)
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.m)
            Hairline()
        }
    }
}
