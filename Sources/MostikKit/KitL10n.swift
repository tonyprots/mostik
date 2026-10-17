import MostikCore

/// Строка интерфейса в платформенном слое: русский и английский рядом.
/// Язык общий с MostikUI (`UIText.isRussian`).
@inline(__always)
func L(_ ru: String, _ en: String) -> String { UIText.pick(ru, en) }
