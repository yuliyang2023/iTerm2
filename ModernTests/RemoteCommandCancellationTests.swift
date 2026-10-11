import XCTest
@testable import iTerm2SharedARC

private final class RemoteCommandRecordingSession: PTYSession {
    var writes = [String]()

    override func writeTaskNoBroadcast(_ string: String) {
        writes.append(string)
    }
}

final class RemoteCommandCancellationTests: XCTestCase {
    func testShellIntegrationAssumptionDefaultsOffAndIsSessionLocal() {
        let first = RemoteCommandRecordingSession(synthetic: false)!
        let second = RemoteCommandRecordingSession(synthetic: false)!
        XCTAssertFalse(first.runningRemoteCommand.assumeShellIntegration)
        first.runningRemoteCommand.assumeShellIntegration = true
        XCTAssertFalse(second.runningRemoteCommand.assumeShellIntegration)
    }

    func testAssumedIntegrationSendsSingleAndMultilineCommandsUnchanged() {
        let commands = [
            "ps -A -o %cpu,%mem,comm -r | head -n 11",
            "# first line\necho '中😀'\npwd # last line",
            "echo first\r\necho second"
        ]
        for command in commands {
            XCTAssertEqual(RunningRemoteCommand.shellInput(command: command,
                                                          completionMarker: "unused-marker",
                                                          assumeShellIntegration: true),
                           command + "\r")
        }
    }

    func testAssumedIntegrationUsesPromptWaitWithoutDetectedPrompt() {
        let session = RemoteCommandRecordingSession(synthetic: false)!
        XCTAssertNil(session.currentCommand)
        session.runningRemoteCommand.assumeShellIntegration = true
        let command = "echo first\necho second"
        var responses = [String]()
        session.executeCommandRemoteCommand(executeCommand: .init(command: command)) { output, _ in
            responses.append(output)
        }
        XCTAssertEqual(session.writes, [command + "\r"])
        guard case .waitingForMark = session.runningRemoteCommand.state else {
            XCTFail("Forced integration must wait for a prompt, not a completion marker")
            session.cancelRemoteCommand()
            return
        }
        XCTAssertTrue(responses.isEmpty)
        session.cancelRemoteCommand(interrupt: true)
        session.cancelRemoteCommand(interrupt: true)
        XCTAssertEqual(responses, ["The function call was canceled by user request."])
        XCTAssertEqual(session.writes, [command + "\r", "\u{03}"])
        XCTAssertFalse(session.isExecutingRemoteCommand)
        XCTAssertTrue(session.runningRemoteCommand.assumeShellIntegration)
    }

    func testDisabledAssumptionKeepsCompletionMarkerFallback() {
        let session = RemoteCommandRecordingSession(synthetic: false)!
        XCTAssertNil(session.currentCommand)
        session.executeCommandRemoteCommand(executeCommand: .init(command: "pwd")) { _, _ in }
        guard case .expectation = session.runningRemoteCommand.state else {
            XCTFail("Without integration or its override, keep the original marker path")
            session.cancelRemoteCommand()
            return
        }
        XCTAssertEqual(session.writes.count, 1)
        XCTAssertTrue(session.writes.first?.hasPrefix("eval 'pwd'; echo '-- FINISHED' ") == true)
        session.cancelRemoteCommand()
    }

    func testInterruptCancelsPromptWaitExactlyOnce() {
        let session = RemoteCommandRecordingSession(synthetic: false)!
        var responses = [String]()
        session.runningRemoteCommand.state = .waitingForMark(UUID(), OneTimeStringClosure {
            responses.append($0)
            XCTAssertFalse(session.isExecutingRemoteCommand)
            XCTAssertEqual(session.writes, ["\u{03}"])
        })
        session.cancelRemoteCommand(interrupt: true)
        session.cancelRemoteCommand(interrupt: true)
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(session.writes, ["\u{03}"])
    }

    func testCancelWithoutInterruptDoesNotSendKeys() {
        let session = RemoteCommandRecordingSession(synthetic: false)!
        var responses = 0
        session.runningRemoteCommand.state = .waitingForMark(UUID(), OneTimeStringClosure { _ in
            responses += 1
        })
        session.cancelRemoteCommand()
        XCTAssertEqual(responses, 1)
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testCancelNonTerminalWorkDoesNotInterruptShell() {
        let session = RemoteCommandRecordingSession(synthetic: false)!
        var responses = 0
        session.runningRemoteCommand.state = .futureString(OneTimeStringClosure { _ in
            responses += 1
        })
        session.cancelRemoteCommand(interrupt: true)
        XCTAssertEqual(responses, 1)
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testInterruptCancelsCompletionMarkerWait() {
        let session = RemoteCommandRecordingSession(synthetic: false)!
        let expectation = session.addExpectation("^never-matches", after: nil, deadline: nil,
                                                 willExpect: nil) { _ in
            XCTFail("Canceled expectation must not match")
        }
        var responses = 0
        session.runningRemoteCommand.state = .expectation(expectation, { _ in
            responses += 1
        })
        session.cancelRemoteCommand(interrupt: true)
        session.cancelRemoteCommand(interrupt: true)
        XCTAssertFalse(session.isExecutingRemoteCommand)
        XCTAssertEqual(responses, 1)
        XCTAssertEqual(session.writes, ["\u{03}"])
    }

    func testMultilineScriptAndMarkerSurviveCommentsAndQuotes() throws {
        let script = "# initial comment\r\nvalue=hello\r\nprintf '%s\\n' \"$value\"\nprintf '%s\\n' \"it's quoted\" # final comment"
        let input = RunningRemoteCommand.shellInput(command: script, completionMarker: "test-marker")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", String(input.dropLast())]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello\nit's quoted\n-- FINISHED test-marker\n")
    }

    func testOrdinaryCommandKeepsOriginalShellInput() {
        XCTAssertEqual(RunningRemoteCommand.shellInput(command: "pwd"), "pwd\r")
    }
}
