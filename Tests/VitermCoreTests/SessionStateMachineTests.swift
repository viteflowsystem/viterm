import Foundation
import Testing
@testable import VitermCore

/// Test detector. Rewriting `signal` lets us simulate output changes over time.
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

        // t=0.6: output stopped (spinner etc. disappeared) → idle candidate starts.
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

        // t=0.5: output stopped → idle candidate starts.
        stub.signal = .none
        machine.recordOutput(screenLines: ["done"], at: t0.addingTimeInterval(0.5))

        // t=1.0: a busy signal arrived again → the idle candidate is reset.
        stub.signal = .busy
        machine.recordOutput(screenLines: ["esc to interrupt"], at: t0.addingTimeInterval(1.0))

        // Without the reset, idle would be confirmed at 0.5+1.5=2.0;
        // with the reset, the state is still busy as of t=1.0.
        #expect(machine.currentState(at: t0.addingTimeInterval(2.1)) == .busy)

        // t=1.1: output stopped again → the idle candidate is re-counted from this point.
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
        // Output arriving within the suppression window (within 250ms) — normally a busy signal — is ignored.
        machine.recordOutput(screenLines: ["garbled redraw"], at: t0.addingTimeInterval(0.1))
        #expect(machine.currentState(at: t0.addingTimeInterval(0.1)) == .idle)

        // Once past the suppression window, detection works as usual.
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
        // t=0: output stopped → idle candidate starts (idle should be confirmed at t=1.0, 1.0s later).
        machine.recordOutput(screenLines: ["done"], at: t0)

        // t=0.9: suppose a resize occurs just before the debounce expires (t=1.0). Suppression window is 0.9-1.4.
        machine.recordResize(at: t0.addingTimeInterval(0.9))

        // Inside the suppression window, the state does not become idle even at t=1.0 where it normally would.
        #expect(machine.currentState(at: t0.addingTimeInterval(1.0)) == .busy)
        // After the suppression window ends (t=1.5), idle is confirmed via the normal idle debounce elapse.
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
