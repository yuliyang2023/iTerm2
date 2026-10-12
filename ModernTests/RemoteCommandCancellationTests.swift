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

    func testStopBeforeQueuedExpectationCallbackNeverSendsCommand() {
        let session = RemoteCommandRecordingSession(synthetic: false)!
        var responses = [String]()
        session.executeCommandRemoteCommand(executeCommand: .init(command: "echo should-not-run")) { output, _ in
            responses.append(output)
        }
        // Copying queues the real main-thread willExpect callback. Stop wins
        // before it runs, even though the mutation-thread snapshot still exists.
        let wetExpect = session.expect.copy() as! iTermExpect
        session.cancelRemoteCommand(interrupt: true)
        let drained = expectation(description: "Delayed command send drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(session.writes, ["\u{03}"])
        XCTAssertEqual(responses, ["The function call was canceled by user request."])
        withExtendedLifetime(wetExpect) {}
    }

    func testReadOnlyToolPreservesAnotherChatsCommand() throws {
        let harness = TerminalTestHarness()
        let session = RemoteCommandRecordingSession(synthetic: false)!
        session.screen = harness.screen
        session.runningRemoteCommand.bastionCompatibilityEnabled = true
        var commandResponses = 0
        session.executeCommandRemoteCommand(executeCommand: .init(command: "sleep 60")) { _, _ in
            commandResponses += 1
        }
        let request = RemoteCommand(llmMessage: LLM.Message(role: .assistant, body: .text("")),
                                    content: .getScreenContents(.init(lines: 10)))
        var readResponses = 0
        try session.execute(request) { _, _ in readResponses += 1 }
        XCTAssertEqual(readResponses, 1)
        XCTAssertEqual(commandResponses, 0)
        XCTAssertTrue(session.isExecutingRemoteCommand)
        XCTAssertEqual(session.writes, ["sleep 60\r"])
        session.cancelRemoteCommand()
    }

    func testConflictingInputDoesNotCancelOrWriteIntoActiveCommand() throws {
        let harness = TerminalTestHarness()
        let session = RemoteCommandRecordingSession(synthetic: false)!
        session.screen = harness.screen
        session.runningRemoteCommand.bastionCompatibilityEnabled = true
        var responses = 0
        session.executeCommandRemoteCommand(executeCommand: .init(command: "sleep 60")) { _, _ in responses += 1 }
        for content in [RemoteCommand.Content.executeCommand(.init(command: "pwd")),
                        .getManPage(.init(cmd: "ls")), .insertTextAtCursor(.init(text: "pwd\\n")),
                        .deleteCurrentLine(.init()), .restartSession(.init())] {
            let request = RemoteCommand(llmMessage: LLM.Message(role: .assistant, body: .text("")), content: content)
            XCTAssertThrowsError(try session.execute(request) { _, _ in XCTFail("Conflicting input executed") })
        }
        XCTAssertEqual(session.writes, ["sleep 60\r"])
        XCTAssertEqual(responses, 0)
        XCTAssertTrue(session.isExecutingRemoteCommand)
        session.cancelRemoteCommand()
    }

    func testBusyShellDoesNotReceiveApprovedCommand() {
        let harness = TerminalTestHarness()
        let session = RemoteCommandRecordingSession(synthetic: false)!
        session.screen = harness.screen
        harness.sendPromptStart()
        harness.appendText("$ ")
        harness.sendCommandStart()
        harness.appendText("python")
        harness.newline()
        harness.sendCommandEnd()
        harness.sync()
        XCTAssertTrue(session.screen.shouldExpectPromptMarks())
        XCTAssertNil(session.currentCommand)
        for raw in [false, true] {
            session.runningRemoteCommand.bastionCompatibilityEnabled = raw
            var response = ""
            session.executeCommandRemoteCommand(executeCommand: .init(command: "pwd")) { output, _ in
                response = output
            }
            XCTAssertTrue(response.contains("not sent"))
        }
        XCTAssertTrue(session.writes.isEmpty)
        XCTAssertFalse(session.isExecutingRemoteCommand)
    }

    func testUnfinishedInputIsNotCombinedWithApprovedCommand() throws {
        let harness = TerminalTestHarness()
        let session = RemoteCommandRecordingSession(synthetic: false)!
        session.screen = harness.screen
        harness.sendPromptStart()
        harness.appendText("$ ")
        harness.sendCommandStart()
        harness.appendText("rm ")
        harness.sync()
        XCTAssertTrue(session.currentCommand?.hasPrefix("rm") == true)
        let command = RemoteCommand(llmMessage: LLM.Message(role: .assistant, body: .text("")),
                                    content: .executeCommand(.init(command: "pwd")))
        XCTAssertThrowsError(try session.execute(command) { _, _ in XCTFail("Unfinished input executed") })
        XCTAssertTrue(session.writes.isEmpty)
    }
}

@MainActor
final class ChatRemoteCommandApprovalTests: XCTestCase {
    private class NoRegistration: AIRegistrationProvider {
        func registrationProviderRequestRegistration(_ completion: @escaping (AITermController.Registration?) -> ()) {
            completion(nil)
        }
    }

    private func makeBroker() throws -> ChatBroker {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try XCTUnwrap(ChatDatabase(url: directory.appendingPathComponent("chat.sqlite")))
        return ChatBroker(listModel: try XCTUnwrap(ChatListModel(database: database)))
    }

    private func addChat(_ broker: ChatBroker, reference: String? = "first") throws -> String {
        let chat = Chat(title: "Approval test", terminalSessionGuid: reference,
                        browserSessionGuid: nil, permissions: "")
        try broker.listModel.add(chat: chat)
        if let reference {
            try broker.listModel.setPermission(chat: chat.id, permission: .ask,
                                               guid: reference, category: .runCommands)
        }
        return chat.id
    }

    private func request(_ chatID: String, content: RemoteCommand.Content = .executeCommand(.init(command: "pwd"))) -> Message {
        let id = UUID().uuidString
        let llm = LLM.Message(role: .assistant,
                              body: .functionCall(LLM.FunctionCall(name: content.functionName,
                                                                  arguments: "{}", id: id, thoughtSignature: nil),
                                                   id: .init(callID: id, itemID: id)))
        return Message(chatID: chatID, author: .agent,
                       content: .remoteCommandRequest(.classic(.init(llmMessage: llm, content: content)), safe: true),
                       sentDate: Date(), uniqueID: UUID())
    }

    private func terminal() -> (RemoteCommandRecordingSession, TerminalTestHarness) {
        let harness = TerminalTestHarness()
        let session = RemoteCommandRecordingSession(synthetic: false)!
        session.screen = harness.screen
        session.runningRemoteCommand.bastionCompatibilityEnabled = true
        return (session, harness)
    }

    func testDuplicateApprovalCannotExecuteWhileRunningOrAfterCompletion() throws {
        let broker = try makeBroker()
        let chatID = try addChat(broker)
        let (session, harness) = terminal()
        let client = ChatClient(broker: broker, sessionForReference: { _ in session })
        let message = request(chatID)
        try client.publish(message: message, toChatID: chatID, partial: false)
        client.decideRemoteCommandRequest(chatID: chatID, requestID: message.uniqueID, decision: .allowOnce)
        client.decideRemoteCommandRequest(chatID: chatID, requestID: message.uniqueID, decision: .allowAlways)
        XCTAssertEqual(session.writes, ["pwd\r"])
        harness.appendText("/tmp")
        session.collectRemoteCommandOutput()
        client.decideRemoteCommandRequest(chatID: chatID, requestID: message.uniqueID, decision: .allowOnce)
        XCTAssertEqual(session.writes, ["pwd\r"])
        XCTAssertFalse(client.isRemoteCommandRequestPending(chatID: chatID, requestID: message.uniqueID))
        XCTAssertEqual(RemoteCommandExecutor.instance.permission(chatID: chatID, inSessionGuid: "first", category: .runCommands), .ask)
        withExtendedLifetime(harness) {}
    }

    func testStopInvalidatesApprovalAndDelayedRepublication() throws {
        let broker = try makeBroker()
        let chatID = try addChat(broker)
        let (session, harness) = terminal()
        let client = ChatClient(broker: broker, sessionForReference: { _ in session })
        let message = request(chatID)
        try client.publish(message: message, toChatID: chatID, partial: false)
        try client.publishUserMessage(chatID: chatID, content: .userCommand(.stop))
        client.decideRemoteCommandRequest(chatID: chatID, requestID: message.uniqueID, decision: .allowAlways)
        try client.publish(message: message, toChatID: chatID, partial: false)
        XCTAssertFalse(client.isRemoteCommandRequestPending(chatID: chatID, requestID: message.uniqueID))
        XCTAssertTrue(session.writes.isEmpty)
        withExtendedLifetime(harness) {}
    }

    func testSwitchingAwayAndBackCannotReviveOldApproval() throws {
        let broker = try makeBroker()
        let chatID = try addChat(broker)
        let (first, harness) = terminal()
        let (second, secondHarness) = terminal()
        let client = ChatClient(broker: broker, sessionForReference: { $0 == "first" ? first : second })
        let message = request(chatID)
        try client.publish(message: message, toChatID: chatID, partial: false)
        try broker.listModel.setTerminalGuid(for: chatID, to: "second")
        try broker.listModel.setTerminalGuid(for: chatID, to: "first")
        client.decideRemoteCommandRequest(chatID: chatID, requestID: message.uniqueID, decision: .allowAlways)
        XCTAssertTrue(first.writes.isEmpty)
        XCTAssertTrue(second.writes.isEmpty)
        XCTAssertFalse(client.isRemoteCommandRequestPending(chatID: chatID, requestID: message.uniqueID))
        withExtendedLifetime((harness, secondHarness)) {}
    }

    func testSharedDenialStopsBeforeResultAndCannotBeApprovedLater() throws {
        let broker = try makeBroker()
        let chatID = try addChat(broker)
        let (session, harness) = terminal()
        let client = ChatClient(broker: broker, sessionForReference: { _ in session })
        let message = request(chatID)
        var deliveries = [Message]()
        let subscription = broker.subscribe(chatID: chatID, registrationProvider: nil) {
            if case .delivery(let message, _, _) = $0 { deliveries.append(message) }
        }
        defer { subscription.unsubscribe() }
        try client.publish(message: message, toChatID: chatID, partial: false)
        client.decideRemoteCommandRequest(chatID: chatID, requestID: message.uniqueID, decision: .denyAlways)
        XCTAssertTrue(deliveries.contains { if case .userCommand(.stop) = $0.content { return true }; return false })
        XCTAssertFalse(deliveries.contains { if case .remoteCommandResponse = $0.content { return true }; return false },
                       "A denial must be persisted without resuming the AI dispatcher")
        XCTAssertTrue(broker.listModel.messages(forChat: chatID, createIfNeeded: false)!.contains {
            if case .remoteCommandResponse(_, let id, _, _) = $0.content { return id == message.uniqueID }; return false
        })
        client.decideRemoteCommandRequest(chatID: chatID, requestID: message.uniqueID, decision: .allowOnce)
        XCTAssertTrue(session.writes.isEmpty)
        withExtendedLifetime(harness) {}
    }

    func testConflictingChatFailureStopsOnlyItsOwnTurn() throws {
        let broker = try makeBroker()
        let firstID = try addChat(broker)
        let secondID = try addChat(broker)
        let (session, harness) = terminal()
        let client = ChatClient(broker: broker, sessionForReference: { _ in session })
        let first = request(firstID)
        let second = request(secondID)
        try client.publish(message: first, toChatID: firstID, partial: false)
        client.decideRemoteCommandRequest(chatID: firstID, requestID: first.uniqueID, decision: .allowOnce)
        try client.publish(message: second, toChatID: secondID, partial: false)
        client.decideRemoteCommandRequest(chatID: secondID, requestID: second.uniqueID, decision: .allowOnce)
        XCTAssertEqual(session.writes, ["pwd\r"])
        XCTAssertTrue(session.isExecutingRemoteCommand)
        XCTAssertTrue(broker.listModel.messages(forChat: secondID, createIfNeeded: false)!.contains {
            if case .userCommand(.stop) = $0.content { return true }; return false
        })
        try client.publishUserMessage(chatID: firstID, content: .userCommand(.stop))
        XCTAssertEqual(session.writes, ["pwd\r", "\u{03}"])
        withExtendedLifetime(harness) {}
    }

    func testCancelledSessionPickerCannotRepublishOrResume() throws {
        let broker = try makeBroker()
        let chatID = try addChat(broker, reference: nil)
        let client = ChatClient(broker: broker, sessionForReference: { _ in nil })
        let message = request(chatID)
        try client.publish(message: message, toChatID: chatID, partial: false)
        XCTAssertTrue(client.isRemoteCommandRequestPending(chatID: chatID, requestID: message.uniqueID))
        client.decideRemoteCommandRequest(chatID: chatID, requestID: message.uniqueID, decision: .denyOnce)
        try client.publish(message: message, toChatID: chatID, partial: false)
        XCTAssertFalse(client.isRemoteCommandRequestPending(chatID: chatID, requestID: message.uniqueID))
        XCTAssertTrue(broker.listModel.messages(forChat: chatID, createIfNeeded: false)!.contains {
            $0.uniqueID == message.uniqueID
        }, "The denied picker must preserve the original tool call for history")
    }

    func testAutomaticExecutionFailureStopsAndPreservesOtherCommand() throws {
        let broker = try makeBroker()
        let chatID = try addChat(broker)
        let (session, harness) = terminal()
        let client = ChatClient(broker: broker, sessionForReference: { _ in session })
        var interrupted = false
        session.runningRemoteCommand.state = .waitingForMark(UUID(), OneTimeStringClosure { _ in interrupted = true })
        try broker.listModel.setPermission(chat: chatID, permission: .always, guid: "first", category: .runCommands)
        let message = request(chatID)
        try client.publish(message: message, toChatID: chatID, partial: false)
        XCTAssertFalse(interrupted)
        XCTAssertTrue(session.writes.isEmpty)
        XCTAssertTrue(session.isExecutingRemoteCommand)
        let messages = try XCTUnwrap(broker.listModel.messages(forChat: chatID, createIfNeeded: false))
        XCTAssertTrue(messages.contains { if case .userCommand(.stop) = $0.content { return true }; return false })
        XCTAssertTrue(messages.contains {
            if case .remoteCommandResponse(_, let id, _, _) = $0.content { return id == message.uniqueID }; return false
        })
        session.cancelRemoteCommand()
        withExtendedLifetime(harness) {}
    }

    func testSessionTerminationInvalidatesPendingApproval() throws {
        let broker = try makeBroker()
        let chatID = try addChat(broker)
        let (session, harness) = terminal()
        let client = ChatClient(broker: broker, sessionForReference: { _ in session })
        let message = request(chatID)
        try client.publish(message: message, toChatID: chatID, partial: false)
        NotificationCenter.default.post(name: .iTermSessionWillTerminate, object: session)
        client.decideRemoteCommandRequest(chatID: chatID, requestID: message.uniqueID, decision: .allowOnce)
        XCTAssertFalse(client.isRemoteCommandRequestPending(chatID: chatID, requestID: message.uniqueID))
        XCTAssertTrue(session.writes.isEmpty)
        withExtendedLifetime(harness) {}
    }

    func testStopDuringSafetyCheckResolvesOnceWithoutPublishingLateRequest() async throws {
        let broker = try makeBroker()
        let chatID = try addChat(broker, reference: nil)
        let agent = ChatAgent(chatID, broker: broker, mode: .sessionBound,
                              registrationProvider: NoRegistration(), messages: [])
        let started = expectation(description: "Safety check started")
        let returned = expectation(description: "Safety check returned after Stop")
        var resumeCheck: CheckedContinuation<Bool, Never>?
        agent.commandSafetyCheck = { _, _, _ in
            let result = await withCheckedContinuation { continuation in
                resumeCheck = continuation
                started.fulfill()
            }
            returned.fulfill()
            return result
        }
        var published = 0
        let subscription = broker.subscribe(chatID: chatID, registrationProvider: nil) {
            if case .delivery(let message, _, _) = $0,
               case .remoteCommandRequest = message.content { published += 1 }
        }
        defer { subscription.unsubscribe(); agent.stop() }
        guard case .remoteCommandRequest(let payload, _) = request(chatID).content,
              let command = payload.classic else { return XCTFail("Missing fixture command") }
        var completions = 0
        try agent.runRemoteCommand(command, nil) { result in
            completions += 1
            if case .success = result { XCTFail("Stopped command succeeded") }
        }
        await fulfillment(of: [started], timeout: 5)
        agent.stop()
        XCTAssertEqual(completions, 1)
        resumeCheck?.resume(returning: true)
        await fulfillment(of: [returned], timeout: 5)
        // Drain the safety task after the injected check returns.
        await Task.yield()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(published, 0)
    }
}
