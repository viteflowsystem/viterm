import Foundation
import Testing
@testable import VitermCore

/// テスト用の detector。`signal` を書き換えることで、時系列に沿った出力の変化を模擬できる。
private final class MutableStubDetector: StateDetector, @unchecked Sendable {
    let toolName = "stub"
    var signal: DetectionSignal

    init(signal: DetectionSignal) {
        self.signal = signal
    }

    func detect(screenLines: [String]) -> DetectionSignal { signal }
}

@Suite("SessionStateMachine")
struct SessionStateMachineTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("初期状態はidle(既定)")
    func initialStateIsIdle() {
        let machine = SessionStateMachine(detector: MutableStubDetector(signal: .none))
        #expect(machine.currentState(at: t0) == .idle)
    }

    @Test("busyシグナルは即座に確定する")
    func busySignalIsImmediate() {
        var machine = SessionStateMachine(detector: MutableStubDetector(signal: .busy))
        machine.recordOutput(screenLines: ["esc to interrupt"], at: t0)
        #expect(machine.currentState(at: t0) == .busy)
    }

    @Test("waitingInputシグナルは即座に確定する")
    func waitingInputSignalIsImmediate() {
        var machine = SessionStateMachine(detector: MutableStubDetector(signal: .waitingInput))
        machine.recordOutput(screenLines: ["Do you want to proceed?"], at: t0)
        #expect(machine.currentState(at: t0) == .waitingInput)
    }

    @Test("出力が止まってから1.5秒経過するまでidleに確定しない")
    func idleIsDebounced() {
        let stub = MutableStubDetector(signal: .busy)
        var machine = SessionStateMachine(
            detector: stub,
            configuration: .init(idleDebounce: 1.5, resizeSuppressionWindow: 0.25)
        )
        machine.recordOutput(screenLines: ["esc to interrupt"], at: t0)
        #expect(machine.currentState(at: t0) == .busy)

        // t=0.6: 出力が止まった(スピナー等が消えた) → idle candidate 開始。
        stub.signal = .none
        machine.recordOutput(screenLines: ["done"], at: t0.addingTimeInterval(0.6))

        #expect(machine.currentState(at: t0.addingTimeInterval(1.5)) == .busy, "1.5秒経過前はまだbusyのまま")
        #expect(machine.currentState(at: t0.addingTimeInterval(2.0)) == .busy, "ちょうど1.5秒経過直前(0.6+1.5=2.1)はまだ確定しない")
        #expect(machine.currentState(at: t0.addingTimeInterval(2.2)) == .idle, "0.6+1.5秒経過後にidleが確定する")
    }

    @Test("デバウンス中にbusyシグナルが再度来るとidleカウントダウンがリセットされる")
    func busySignalResetsIdleCountdown() {
        let stub = MutableStubDetector(signal: .busy)
        var machine = SessionStateMachine(detector: stub, initialState: .busy)

        // t=0.5: 出力が止まった → idle candidate 開始。
        stub.signal = .none
        machine.recordOutput(screenLines: ["done"], at: t0.addingTimeInterval(0.5))

        // t=1.0: 再びbusyシグナルが来た → idle candidate はリセットされる。
        stub.signal = .busy
        machine.recordOutput(screenLines: ["esc to interrupt"], at: t0.addingTimeInterval(1.0))

        // リセットされていなければ 0.5+1.5=2.0 でidle確定してしまうが、
        // リセットされていれば t=1.0 の時点ではまだ busy のまま。
        #expect(machine.currentState(at: t0.addingTimeInterval(2.1)) == .busy)

        // t=1.1: 再び出力が止まった → idle candidate がこの時刻から数え直される。
        stub.signal = .none
        machine.recordOutput(screenLines: ["done"], at: t0.addingTimeInterval(1.1))
        #expect(machine.currentState(at: t0.addingTimeInterval(2.5)) == .busy, "1.1+1.5=2.6秒より前はまだ確定しない")
        #expect(machine.currentState(at: t0.addingTimeInterval(2.7)) == .idle)
    }

    @Test("リサイズ直後は判定が抑制され状態が変化しない")
    func resizeSuppressesDetectionBriefly() {
        let stub = MutableStubDetector(signal: .busy)
        var machine = SessionStateMachine(
            detector: stub,
            configuration: .init(idleDebounce: 1.5, resizeSuppressionWindow: 0.25),
            initialState: .idle
        )
        machine.recordResize(at: t0)
        // 抑制ウィンドウ内(250ms以内)に来た出力(本来ならbusyシグナル)は無視される。
        machine.recordOutput(screenLines: ["garbled redraw"], at: t0.addingTimeInterval(0.1))
        #expect(machine.currentState(at: t0.addingTimeInterval(0.1)) == .idle)

        // 抑制ウィンドウを過ぎれば通常通り判定される。
        machine.recordOutput(screenLines: ["esc to interrupt"], at: t0.addingTimeInterval(0.3))
        #expect(machine.currentState(at: t0.addingTimeInterval(0.3)) == .busy)
    }

    @Test("リサイズはidleデバウンスの経過判定も凍結する")
    func resizeFreezesIdleDebounceExpiry() {
        let stub = MutableStubDetector(signal: .none)
        var machine = SessionStateMachine(
            detector: stub,
            configuration: .init(idleDebounce: 1.0, resizeSuppressionWindow: 0.5),
            initialState: .busy
        )
        // t=0: 出力が止まった → idle candidate 開始(1.0秒後の t=1.0 でidle確定するはず)。
        machine.recordOutput(screenLines: ["done"], at: t0)

        // t=0.9: debounce満了(t=1.0)の直前にリサイズが起きたとする。抑制ウィンドウは 0.9〜1.4。
        machine.recordResize(at: t0.addingTimeInterval(0.9))

        // 抑制ウィンドウ内では、本来ならidle確定するt=1.0地点でもidleにならない。
        #expect(machine.currentState(at: t0.addingTimeInterval(1.0)) == .busy)
        // 抑制ウィンドウが明けた後(t=1.5)は通常通りidle debounceの経過で確定する。
        #expect(machine.currentState(at: t0.addingTimeInterval(1.5)) == .idle)
    }

    @Test("カスタム設定値(idleDebounce)が反映される")
    func customConfigurationIsRespected() {
        let stub = MutableStubDetector(signal: .none)
        var machine = SessionStateMachine(
            detector: stub,
            configuration: .init(idleDebounce: 3.0, resizeSuppressionWindow: 0.25),
            initialState: .busy
        )
        machine.recordOutput(screenLines: ["done"], at: t0)
        #expect(machine.currentState(at: t0.addingTimeInterval(1.5)) == .busy, "既定の1.5sでは確定しないカスタム設定")
        #expect(machine.currentState(at: t0.addingTimeInterval(3.1)) == .idle)
    }
}
