import XCTest
@testable import iTerm2SharedARC

private final class RemoteCommandRecordingSession: PTYSession {
    var writes = [String]()
    var didWrite: ((String) -> Void)?

    override func writeTaskNoBroadcast(_ string: String) {
        writes.append(string)
        didWrite?(string)
    }
}

final class RemoteCommandCancellationTests: XCTestCase {
    func testUnwrappedInputPreservesCommandAndOnlyNormalizesReturnKeys() {
        let command = "ps -A -o %cpu,%mem,comm -r | head -n 11"
        XCTAssertEqual(RunningRemoteCommand.unwrappedShellInput(command: command), command + "\r")
        XCTAssertEqual(RunningRemoteCommand.unwrappedShellInput(command: "echo '中😀'\r\npwd\n"),
                       "echo '中😀'\rpwd\r")
        XCTAssertEqual(RunningRemoteCommand.unwrappedShellInput(command: "pwd\r"), "pwd\r")
    }

    func testKeystrokeExecutionWaitsForManualCollectionWithoutShellIntegration() {
        let session = RemoteCommandRecordingSession(synthetic: false)!
        session.runningRemoteCommand.keystrokeInputEnabled = true
        let submitted = expectation(description: "Unwrapped command submitted")
        var responses = [String]()
        var collections = 0
        session.didWrite = { key in
            if key == "\r" { submitted.fulfill() }
        }
        session.executeCommandRemoteCommand(executeCommand: .init(command: "pwd"),
                                           collectingOutput: { collections += 1 }) { output, _ in
            responses.append(output)
        }
        // A click during typing must not truncate or collect unfinished input.
        XCTAssertFalse(session.canCollectRemoteCommandOutput)
        session.collectRemoteCommandOutput()
        XCTAssertTrue(responses.isEmpty)
        wait(for: [submitted], timeout: 5)
        XCTAssertEqual(session.writes, ["p", "w", "d", "\r"])
        XCTAssertTrue(session.isExecutingRemoteCommand)
        XCTAssertTrue(session.canCollectRemoteCommandOutput)
        XCTAssertTrue(responses.isEmpty)
        session.collectRemoteCommandOutput()
        session.collectRemoteCommandOutput()
        XCTAssertEqual(responses.count, 1)
        XCTAssertTrue(responses.first?.contains("Command completion and exit status were not verified") == true)
        XCTAssertEqual(collections, 1)
        XCTAssertFalse(session.isExecutingRemoteCommand)
        XCTAssertFalse(session.canCollectRemoteCommandOutput)
        XCTAssertEqual(session.writes, ["p", "w", "d", "\r"])
    }

    func testCancelManualCollectionInterruptsExactlyOnce() {
        let session = RemoteCommandRecordingSession(synthetic: false)!
        var responses = [String]()
        session.runningRemoteCommand.state = .waitingForUser(OneTimeStringClosure { responses.append($0) })
        session.cancelRemoteCommand(interrupt: true)
        session.collectRemoteCommandOutput()
        session.cancelRemoteCommand(interrupt: true)
        XCTAssertEqual(responses, ["The function call was canceled by user request."])
        XCTAssertEqual(session.writes, ["\u{03}"])
        XCTAssertFalse(session.canCollectRemoteCommandOutput)
    }

    func testKeystrokeInputIsSessionLocalAndDisabledByDefault() {
        let first = RemoteCommandRecordingSession(synthetic: false)!
        let second = RemoteCommandRecordingSession(synthetic: false)!
        XCTAssertFalse(first.runningRemoteCommand.keystrokeInputEnabled)
        first.runningRemoteCommand.keystrokeInputEnabled = true
        XCTAssertFalse(second.runningRemoteCommand.keystrokeInputEnabled)
        second.sendRemoteCommandInput("pwd\r")
        XCTAssertEqual(second.writes, ["pwd\r"])
    }

    func testKeystrokeInputPreservesUnicodeAndSubmitsLast() {
        let session = RemoteCommandRecordingSession(synthetic: false)!
        session.runningRemoteCommand.keystrokeInputEnabled = true
        session.runningRemoteCommand.state = .waitingForMark(UUID(), OneTimeStringClosure { _ in })
        let submitted = expectation(description: "Command submitted")
        session.didWrite = { key in
            if key == "\r" { submitted.fulfill() }
        }
        session.sendRemoteCommandInput("中😀e\u{301}\r")
        wait(for: [submitted], timeout: 5)
        XCTAssertEqual(session.writes, ["中", "😀", "e", "\u{301}", "\r"])
        session.cancelRemoteCommand()
    }

    func testCancelBeforeFirstKeyPreventsSubmission() {
        let session = RemoteCommandRecordingSession(synthetic: false)!
        session.runningRemoteCommand.keystrokeInputEnabled = true
        session.runningRemoteCommand.state = .waitingForMark(UUID(), OneTimeStringClosure { _ in })
        session.sendRemoteCommandInput("pwd\r")
        session.cancelRemoteCommand(interrupt: true)
        let drained = expectation(description: "Queued first key checked cancellation")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(session.writes, ["\u{03}"])
        XCTAssertNil(session.runningRemoteCommand.pendingInputID)
    }

    func testCancelDuringKeystrokeInputStopsRemainingKeys() {
        let session = RemoteCommandRecordingSession(synthetic: false)!
        session.runningRemoteCommand.keystrokeInputEnabled = true
        session.runningRemoteCommand.state = .waitingForMark(UUID(), OneTimeStringClosure { _ in })
        let replacementSubmitted = expectation(description: "Replacement command submitted")
        session.didWrite = { [weak session] key in
            guard let session else { return }
            if key == "p" {
                session.cancelRemoteCommand(interrupt: true)
                XCTAssertNil(session.runningRemoteCommand.pendingInputID)
                session.runningRemoteCommand.state = .waitingForMark(UUID(), OneTimeStringClosure { _ in })
                session.sendRemoteCommandInput("XY\r")
            } else if key == "\r" {
                replacementSubmitted.fulfill()
            }
        }
        session.sendRemoteCommandInput("pwd\r")
        wait(for: [replacementSubmitted], timeout: 5)
        // Waiting for the replacement also drains the old command's next-key
        // callback, proving it cannot write into the new execution.
        XCTAssertEqual(session.writes, ["p", "\u{03}", "X", "Y", "\r"])
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
