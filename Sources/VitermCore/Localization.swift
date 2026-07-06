import Foundation

/// モジュール内リソースバンドルの Localizable カタログから文字列を解決する。
/// UI に出る文字列は必ずこれを通す(ベース言語は英語、日本語はカタログで供給)。
@inline(__always)
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
