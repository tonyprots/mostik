import MostikCore
import SwiftUI

/// Приватность (п. 8): проверка обновлений — строка сводки «Что уходит с этого Mac». Выключателя нет:
/// проверка всегда включена (решение автора), иначе никто не узнал бы о починке безопасности.
/// Строка есть только в выпуске с настоящей лентой.
struct UpdateChecksSection: View {
    var body: some View {
        FormRow(title: L("Проверка обновлений", "Update checks"),
                hint: L("Раз в день: номер версии и адрес компьютера — серверу обновлений.",
                        "Once a day: the version number and your computer’s address go to the update server."),
                details: L("Лента обновлений лежит на GitHub (tonyprots.github.io), файлы — в GitHub Releases. Новая версия ставится только по вашей кнопке в окне обновления. Выключить проверку нельзя: иначе вы не узнали бы о починке безопасности.",
                           "The update feed is on GitHub (tonyprots.github.io), the files are in GitHub Releases. A new version installs only when you click in the update window. Checks can’t be turned off: otherwise you’d never hear about a security fix."),
                status: Palette.doubt) {
            EmptyView()
        }
        .accessibilityElement(children: .combine)
    }
}
