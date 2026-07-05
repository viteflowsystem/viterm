import Foundation

/// `StateDetector` が画面テキストから即時に読み取れるシグナル。
/// デバウンスや経過時間の判断は含まない、純粋なテキストマッチの結果。
/// `.none` は「busy/waitingInput の明確な根拠が無い」ことを示すだけで、
/// idle が確定したことを意味しない(確定は `SessionStateMachine` のデバウンス層が行う)。
public enum DetectionSignal: Sendable, Equatable {
    case busy
    case waitingInput
    case none
}

/// エージェントセッションの画面テキストから状態シグナルを検出するツール別ストラテジ。
/// PTY / libghostty 等の実行環境には一切依存せず、文字列(仮想画面の行配列)のみを入力とする。
public protocol StateDetector: Sendable {
    /// この detector が対応するツール名(`SessionPreset.name` 等と対応させる想定)。
    var toolName: String { get }

    /// 現在の画面内容(スクロールバックを含まない、可視行のみ)からシグナルを判定する。
    func detect(screenLines: [String]) -> DetectionSignal
}
