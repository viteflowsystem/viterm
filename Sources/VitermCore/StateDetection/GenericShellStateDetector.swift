import Foundation

/// 素のシェル(zsh/bash等)向けの detector。
/// エージェントCLIと違い、任意コマンドは自身の状態を画面テキストで宣言しないため、
/// 「確認待ち(waitingInput)」を一般化して検出することはできない。
/// 代わりに、画面最下行がシェルプロンプトらしい記号で終わっているかどうかだけを見る:
/// プロンプトで終わっていれば `.none`(= コマンドは実行中でない = idle 候補)、
/// そうでなければ実行中のコマンドが出力中とみなし `.busy` とする。
public struct GenericShellStateDetector: StateDetector {
    public let toolName: String

    public init(toolName: String = "shell") {
        self.toolName = toolName
    }

    public func detect(screenLines: [String]) -> DetectionSignal {
        guard let lastLine = screenLines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return .none
        }
        return Self.looksLikePrompt(lastLine) ? .none : .busy
    }

    static let promptSuffixes: Set<Character> = ["$", "%", "#", ">", "❯"]

    static func looksLikePrompt(_ line: String) -> Bool {
        guard let last = line.trimmingCharacters(in: .whitespaces).last else { return false }
        return promptSuffixes.contains(last)
    }
}
