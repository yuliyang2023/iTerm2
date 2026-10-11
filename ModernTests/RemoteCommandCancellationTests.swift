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
    func testBastionCompatibilityDefaultsOffAndIsSessionLocal() {
        let first = RemoteCommandRecordingSession(synthetic: false)!
        let second = RemoteCommandRecordingSession(synthetic: false)!
        XCTAssertFalse(first.runningRemoteCommand.bastionCompatibilityEnabled)
        first.runningRemoteCommand.bastionCompatibilityEnabled = true
        XCTAssertFalse(second.runningRemoteCommand.bastionCompatibilityEnabled)
    }

    func testBastionCompatibilitySendsSingleAndMultilineCommandsUnchanged() {
        let commands = [
            "ps -A -o %cpu,%mem,comm -r | head -n 11",
            "# first line\necho '中😀'\npwd # last line",
            "echo first\r\necho second"
        ]
        for command in commands {
            XCTAssertEqual(RunningRemoteCommand.shellInput(command: command,
                                                          completionMarker: "unused-marker",
                                                          bastionCompatibilityEnabled: true),
                           command + "\r")
        }
    }

    func testBastionCommandCanBeCollectedWithoutIntegrationOrInterrupting() {
        let harness = TerminalTestHarness()
        let session = RemoteCommandRecordingSession(synthetic: false)!
        session.screen = harness.screen
        XCTAssertNil(session.currentCommand)
        session.runningRemoteCommand.bastionCompatibilityEnabled = true
        let command = "pwd"
        var responses = [String]()
        var collections = 0
        session.executeCommandRemoteCommand(executeCommand: .init(command: command), collectingOutput: {
            collections += 1
        }) { output, _ in
            responses.append(output)
        }
        XCTAssertEqual(session.writes, [command + "\r"])
        XCTAssertTrue(session.canCollectRemoteCommandOutput)
        XCTAssertTrue(responses.isEmpty)
        harness.appendText("pwd")
        harness.newline()
        harness.appendText("/home/deployer")
        // Turning the setting off affects only future commands.
        session.runningRemoteCommand.bastionCompatibilityEnabled = false
        session.collectRemoteCommandOutput()
        session.collectRemoteCommandOutput()
        session.cancelRemoteCommand(interrupt: true)
        XCTAssertEqual(collections, 1)
        XCTAssertEqual(responses.count, 1)
        XCTAssertTrue(responses.first?.contains("/home/deployer") == true)
        XCTAssertTrue(responses.first?.contains("exit status were not verified") == true)
        XCTAssertEqual(session.writes, [command + "\r"])
        XCTAssertFalse(session.isExecutingRemoteCommand)
        XCTAssertFalse(session.canCollectRemoteCommandOutput)
        var status = ""
        session.getLastExitStatusRemoteCommand(getLastExitStatus: .init()) { output, _ in
            status = output
        }
        XCTAssertTrue(status.contains("exit status was not verified"))
    }

    func testBastionCancellationInterruptsOnceAndDoesNotCollect() {
        let session = RemoteCommandRecordingSession(synthetic: false)!
        session.runningRemoteCommand.bastionCompatibilityEnabled = true
        var responses = [String]()
        var collections = 0
        session.executeCommandRemoteCommand(executeCommand: .init(command: "pwd"), collectingOutput: {
            collections += 1
        }) { output, _ in responses.append(output) }
        session.cancelRemoteCommand(interrupt: true)
        session.cancelRemoteCommand(interrupt: true)
        session.collectRemoteCommandOutput()
        XCTAssertEqual(responses, ["The function call was canceled by user request."])
        XCTAssertEqual(session.writes, ["pwd\r", "\u{03}"])
        XCTAssertEqual(collections, 0)
        XCTAssertFalse(session.canCollectRemoteCommandOutput)
    }

    func testBastionCancellationWithoutInterruptSendsNoExtraInput() {
        let session = RemoteCommandRecordingSession(synthetic: false)!
        session.runningRemoteCommand.bastionCompatibilityEnabled = true
        var responses = [String]()
        session.executeCommandRemoteCommand(executeCommand: .init(command: "pwd")) { output, _ in
            responses.append(output)
        }
        session.cancelRemoteCommand()
        session.collectRemoteCommandOutput()
        XCTAssertEqual(responses, ["The function call was canceled by user request."])
        XCTAssertEqual(session.writes, ["pwd\r"])
    }

    func testRawSingleLineAutomaticallyCollectsWithRealShellPrompt() {
        let harness = TerminalTestHarness()
        let session = RemoteCommandRecordingSession(synthetic: false)!
        session.screen = harness.screen
        session.runningRemoteCommand.bastionCompatibilityEnabled = true
        harness.sendPromptStart()
        harness.appendText("$ ")
        harness.sendCommandStart()
        let completed = expectation(description: "Real Shell Integration prompt completes command")
        var responses = [String]()
        session.executeCommandRemoteCommand(executeCommand: .init(command: "pwd")) { output, _ in
            responses.append(output)
            completed.fulfill()
        }
        harness.appendText("pwd")
        harness.newline()
        harness.sendCommandEnd()
        harness.appendText("/home/deployer")
        harness.newline()
        harness.sendReturnCode(0)
        harness.sendPromptStart()
        harness.sync()
        wait(for: [completed], timeout: 5)
        session.collectRemoteCommandOutput()
        XCTAssertEqual(responses.count, 1)
        XCTAssertTrue(responses.first?.contains("/home/deployer") == true)
        XCTAssertFalse(session.runningRemoteCommand.lastOutputWasCollectedManually)
        XCTAssertEqual(session.writes, ["pwd\r"])
    }

    func testRawMultilineDoesNotCompleteAtIntermediateShellPrompt() {
        let harness = TerminalTestHarness()
        let session = RemoteCommandRecordingSession(synthetic: false)!
        session.screen = harness.screen
        session.runningRemoteCommand.bastionCompatibilityEnabled = true
        var responses = [String]()
        session.executeCommandRemoteCommand(executeCommand: .init(command: "pwd\npwd")) { output, _ in
            responses.append(output)
        }
        harness.sendPromptStart()
        harness.sync()
        XCTAssertTrue(responses.isEmpty)
        XCTAssertTrue(session.canCollectRemoteCommandOutput)
        session.collectRemoteCommandOutput()
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(session.writes, ["pwd\npwd\r"])
    }

    func testManualCollectionWinsOverQueuedAutomaticCompletion() {
        let harness = TerminalTestHarness()
        let session = RemoteCommandRecordingSession(synthetic: false)!
        session.screen = harness.screen
        session.runningRemoteCommand.bastionCompatibilityEnabled = true
        var responses = [String]()
        session.executeCommandRemoteCommand(executeCommand: .init(command: "pwd")) { output, _ in
            responses.append(output)
        }
        harness.appendText("/home/deployer")
        harness.newline()
        harness.sendPromptStart()
        harness.sync()
        // The prompt callback queues automatic collection on the main queue.
        // A user click or cancellation must consume the pending call only once.
        session.collectRemoteCommandOutput()
        let drained = expectation(description: "Queued automatic completion checked")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(responses.count, 1)
        XCTAssertTrue(session.runningRemoteCommand.lastOutputWasCollectedManually)
    }

    func testShellIntegrationOnlyWaitIgnoresTextPromptTriggers() {
        let harness = TerminalTestHarness()
        var callbacks = 0
        harness.screen.performBlock(joinedThreads: { _, mutableState, _ in
            mutableState.pause(atNextPrompt: { callbacks += 1 }, ignoringTriggerDetectedPrompts: true)
            _ = mutableState.promptDidStart(at: VT100GridAbsCoordMake(0, 0),
                                            wasInCommand: true, detectedByTrigger: true,
                                            freshLine: true, aid: nil)
        })
        harness.sync()
        XCTAssertEqual(callbacks, 0, "A prompt quoted in logs must not complete a raw command")
        harness.appendText("$ ")
        harness.newline()
        harness.sendPromptStart()
        harness.sync()
        XCTAssertEqual(callbacks, 1)
        harness.newline()
        harness.sendPromptStart()
        harness.sync()
        XCTAssertEqual(callbacks, 1)
    }

    func testOrdinaryPromptWaitStillAcceptsTextTriggers() {
        let harness = TerminalTestHarness()
        var callbacks = 0
        harness.screen.performBlock(joinedThreads: { _, mutableState, _ in
            mutableState.pause(atNextPrompt: { callbacks += 1 })
            _ = mutableState.promptDidStart(at: VT100GridAbsCoordMake(0, 0),
                                            wasInCommand: true, detectedByTrigger: true,
                                            freshLine: true, aid: nil)
        })
        harness.sync()
        XCTAssertEqual(callbacks, 1)
    }

    func testDisabledBastionCompatibilityKeepsCompletionMarkerFallback() {
        let session = RemoteCommandRecordingSession(synthetic: false)!
        XCTAssertNil(session.currentCommand)
        let sent = expectation(description: "Fallback command sent after Expect synchronization")
        session.didWrite = { _ in sent.fulfill() }
        session.executeCommandRemoteCommand(executeCommand: .init(command: "pwd")) { _, _ in }
        guard case .expectation = session.runningRemoteCommand.state else {
            XCTFail("Without integration or compatibility mode, keep the original marker path")
            session.cancelRemoteCommand()
            return
        }
        // The main-thread Expect is dry. Production copies it to the mutation
        // thread before dispatching willExpect back to the main queue. This
        // session has no running task, so explicitly perform that synchronization.
        let wetExpect = session.expect.copy() as! iTermExpect
        XCTAssertFalse(wetExpect.dry)
        wait(for: [sent], timeout: 5)
        XCTAssertEqual(session.writes.count, 1)
        XCTAssertTrue(session.writes.first?.hasPrefix("eval 'pwd'; echo '-- FINISHED' ") == true)
        session.cancelRemoteCommand()
        withExtendedLifetime(wetExpect) {}
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
