import Foundation
import MostikUI

// Рендер снимков интерфейса: MostikSnapshots <папка> [--lang ru|en] [--themes both].
// --lang en — английский интерфейс (то же, что MOSTIK_SNAPSHOT_LANG=en);
// --themes both — к каждому светлому снимку тёмный `<имя>-dark` (MOSTIK_SNAPSHOT_THEMES=both);
// --neutral-name — для слепых тестов: в подписях вместо имени продукта «приложение» / «the app»
// (MOSTIK_SNAPSHOT_NEUTRAL=1). В обычных снимках имя остаётся.
var args = Array(CommandLine.arguments.dropFirst())
let neutral = args.contains("--neutral-name")
args.removeAll { $0 == "--neutral-name" }
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
let lang = option("--lang")
let themes = option("--themes")
let path = args.first ?? "/tmp/mostik-snapshots"
MainActor.assumeIsolated {
    Snapshots.render(to: URL(fileURLWithPath: path),
                     english: lang.map { $0 == "en" },
                     bothThemes: themes.map { $0 == "both" },
                     neutralName: neutral ? true : nil)
}
