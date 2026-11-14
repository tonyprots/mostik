import Foundation

/// Чужой файл настроек, который может оказаться символической ссылкой (так хранят `~/.claude/settings.json`
/// менеджеры dotfiles). Атомарная запись по адресу ссылки заменяет саму ссылку обычным файлом, и
/// настоящий файл расходится с тем, что читает агент; копия ссылки — не резервная копия содержимого.
public enum LinkedFile {
    /// Файл, на который в конце концов указывает ссылка; не ссылка — тот же адрес. Цель может ещё
    /// не существовать. Петля или слишком длинная цепочка — nil.
    public static func target(of url: URL, fileManager: FileManager = .default) -> URL? {
        var current = url.standardizedFileURL
        for _ in 0..<16 {
            guard let next = try? fileManager.destinationOfSymbolicLink(atPath: current.path) else { return current }
            current = URL(fileURLWithPath: next, relativeTo: current.deletingLastPathComponent()).standardizedFileURL
        }
        return nil
    }
}
