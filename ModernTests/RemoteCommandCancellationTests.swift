import XCTest
@testable import iTerm2SharedARC

private final class RemoteCommandRecordingSession: PTYSession {
    var writes = [String]()

    override func writeTaskNoBroadcast(_ string: String) {
        writes.append(string)
    }
}

final class RemoteCommandCancellationTests: XCTestCase {
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
