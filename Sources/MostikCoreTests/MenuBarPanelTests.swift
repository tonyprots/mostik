import Foundation
import MostikCore

/// Всплывающее окно строки меню закрывается перед любым своим окном (баг: после «Открыть Mostik» оставалось висеть).
func runMenuBarPanelTests() {
    check(MenuBarPanelPolicy.isMenuBarExtraWindow(className: "MenuBarExtraWindow"), "окно MenuBarExtra")
    check(MenuBarPanelPolicy.isMenuBarExtraWindow(className: "SwiftUI.MenuBarExtraWindow"), "с префиксом модуля")
    check(!MenuBarPanelPolicy.isMenuBarExtraWindow(className: "NSWindow"), "главное окно не трогаем")
    check(!MenuBarPanelPolicy.isMenuBarExtraWindow(className: "NSPanel"), "плашка диктовки не трогается")

    // Страж по исходникам: приложение выводится вперёд только через MenuBarPanel.activateApp(),
    // который сначала закрывает меню. Прямой NSApp.activate снова оставит окно меню висеть.
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Mostik")
    let files = (try? FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)) ?? []
    check(files.count > 5, "исходники приложения найдены: \(sources.path)")
    for file in files where file.pathExtension == "swift" && file.lastPathComponent != "MenuBarPanel.swift" {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check(!text.contains("NSApp.activate("), "\(file.lastPathComponent): NSApp.activate мимо MenuBarPanel.activateApp()")
        check(!text.contains("keyWindow?.close()"), "\(file.lastPathComponent): меню закрывать через MenuBarPanel.dismiss()")
    }
}
