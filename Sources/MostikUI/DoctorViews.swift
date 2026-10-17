import SwiftUI
import MostikCore

/// Группа «Диагностика» в Настройках (R7): что мешает диктовке и как это починить.
/// Строка на проверку: точка статуса, что проверяли, что не так, кнопка «Исправить».
struct DoctorSection: View {
    @ObservedObject var doctor: DoctorModel

    var body: some View {
        FormGroup(title: L("Диагностика", "Diagnostics"), accessory: AnyView(header)) {
            if doctor.checks.isEmpty {
                FormNote(text: L("Диагностика ещё не запускалась.", "Diagnostics haven’t run yet."))
            }
            ForEach(Array(sorted.enumerated()), id: \.element.id) { index, check in
                if index > 0 { FormDivider() }
                row(check)
            }
        }
        .onAppear { doctor.onRun() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            if let at = doctor.checkedAt {
                Text(L("проверено в ", "checked at ") + Fmt.time(at))
                    .font(TType.caption).foregroundStyle(Palette.inkSecondary)
            }
            Button(L("Журналы в Finder", "Logs in Finder")) { doctor.onRevealLogs() }
                .buttonStyle(.mostik(.quiet, compact: true))
            Button(L("Проверить снова", "Check again")) { doctor.onRun() }
                .buttonStyle(.mostik(.secondary, compact: true))
                .disabled(doctor.running)
        }
    }

    /// Проблемы наверх, порядок внутри статуса — как в `Doctor.evaluate`.
    private var sorted: [DoctorCheck] {
        doctor.checks.enumerated()
            .sorted { a, b in
                let (sa, sb) = (rank(a.element.status), rank(b.element.status))
                return sa != sb ? sa < sb : a.offset < b.offset
            }
            .map(\.element)
    }

    private func rank(_ status: DoctorCheck.Status) -> Int {
        switch status {
        case .failed: 0
        case .warning: 1
        case .unknown: 2
        case .ok: 3
        }
    }

    private func row(_ check: DoctorCheck) -> some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                StatusDot(color: color(check.status), size: 7, label: statusLabel(check.status))
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
                VStack(alignment: .leading, spacing: 3) {
                    Text(DoctorModel.title(check.kind)).font(TType.body).foregroundStyle(Palette.ink)
                    Text(check.detail).font(TType.callout).foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.m)
            // «Показать в Finder» нужен и когда всё в порядке: журнал смотрят не только при сбое.
            if let fix = check.fix, check.status != .ok || fix == .showLogs {
                Button(DoctorModel.fixTitle(fix)) { doctor.onFix(fix) }
                    .buttonStyle(.mostik(check.status == .failed ? .primary : .secondary, compact: true))
            }
        }
        .padding(.vertical, DS.Space.s)
        .accessibilityElement(children: .combine)
    }

    /// Смысл точки для VoiceOver: цвет сам по себе не читается.
    private func statusLabel(_ status: DoctorCheck.Status) -> String {
        switch status {
        case .ok: L("в порядке", "OK")
        case .warning: L("внимание", "warning")
        case .failed: L("ошибка", "failed")
        case .unknown: L("не проверено", "not checked")
        }
    }

    private func color(_ status: DoctorCheck.Status) -> Color {
        switch status {
        case .ok: Palette.accent
        case .warning: Palette.doubt
        case .failed: Palette.record
        case .unknown: Palette.inkTertiary
        }
    }
}
