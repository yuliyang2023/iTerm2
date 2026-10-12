//
//  ChatBrokerTurnLifecycleTests.swift
//  iTerm2 ModernTests
//
//  ChatBroker.publish(turnEvent:) is the fan-out for the explicit agent-turn
//  boundary: it updates TurnStatusModel (so a mid-turn subscribe can seed the
//  phone) and delivers a .turnLifecycle update to the chat's subscribers. This is
//  the producer mechanism the ChatService emit sites (agentWorking / finishTurn)
//  call; those turn boundaries are exercised end-to-end by the live harness.
//

import XCTest
@testable import iTerm2SharedARC

@MainActor
final class ChatBrokerTurnLifecycleTests: XCTestCase {
    private class NoRegistration: AIRegistrationProvider {
        func registrationProviderRequestRegistration(
            _ completion: @escaping (AITermController.Registration?) -> ()
        ) {
            completion(nil)
        }
    }

    private func makeBroker() throws -> ChatBroker {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try XCTUnwrap(ChatDatabase(url: dir.appendingPathComponent("chatdb.sqlite")))
        let listModel = try XCTUnwrap(ChatListModel(database: db))
        return ChatBroker(listModel: listModel)
    }

    // publish(turnEvent:) writes the process-wide TurnStatusModel.instance singleton.
    // Track every chatID a test marks in-flight and clear it in tearDown so state
    // doesn't leak across tests (setup/teardown symmetry).
    private var touchedChatIDs: [String] = []

    private func freshChatID() -> String {
        let id = UUID().uuidString
        touchedChatIDs.append(id)
        return id
    }

    override func tearDown() {
        for id in touchedChatIDs {
            TurnStatusModel.instance.set(inProgress: false, chatID: id)
        }
        touchedChatIDs.removeAll()
        super.tearDown()
    }

    func testPublishTurnStartedFansOutAndSetsModel() throws {
        let broker = try makeBroker()
        let chatID = freshChatID()
        var received: [TurnEvent] = []
        let sub = broker.subscribe(chatID: chatID, registrationProvider: nil) { update in
            if case let .turnLifecycle(event) = update { received.append(event) }
        }
        defer { sub.unsubscribe() }

        broker.publish(turnEvent: .started, toChatID: chatID)
        XCTAssertEqual(received, [.started], "a turn event must reach the chat's subscriber")
        XCTAssertTrue(TurnStatusModel.instance.inProgress(chatID: chatID),
                      "publishing .started must mark the turn in flight")
    }

    func testPublishTurnEndedClearsModel() throws {
        let broker = try makeBroker()
        let chatID = freshChatID()
        // Assert the TRANSITION, not just the terminal value: a fresh chatID starts
        // absent (false), so checking only the final false would pass even if
        // publish(turnEvent:) never touched the model. Prove .started sets it true
        // first, so .ended clearing it is load-bearing.
        broker.publish(turnEvent: .started, toChatID: chatID)
        XCTAssertTrue(TurnStatusModel.instance.inProgress(chatID: chatID),
                      ".started must mark the turn in flight before .ended can clear it")
        broker.publish(turnEvent: .ended, toChatID: chatID)
        XCTAssertFalse(TurnStatusModel.instance.inProgress(chatID: chatID),
                       "publishing .ended must clear the in-flight state")
    }

    func testTurnEventOnlyReachesMatchingChat() throws {
        // Subscribe BOTH the target chat and another chat on the SAME broker, so the
        // assertion proves delivery AND filtering: an inverted/never-true chatID
        // filter would fail the matching-received check, not silently pass an
        // empty-vs-empty comparison.
        let broker = try makeBroker()
        let chatID = freshChatID()
        let otherID = freshChatID()
        var matching: [TurnEvent] = []
        var other: [TurnEvent] = []
        let subMatching = broker.subscribe(chatID: chatID, registrationProvider: nil) { update in
            if case let .turnLifecycle(event) = update { matching.append(event) }
        }
        let subOther = broker.subscribe(chatID: otherID, registrationProvider: nil) { update in
            if case let .turnLifecycle(event) = update { other.append(event) }
        }
        defer { subMatching.unsubscribe(); subOther.unsubscribe() }

        broker.publish(turnEvent: .started, toChatID: chatID)
        XCTAssertEqual(matching, [.started], "the chat's own subscriber must receive the event")
        XCTAssertTrue(other.isEmpty, "a subscriber to a different chat must not receive it")
    }

    func testActivityStatusIsScopedAndDoesNotChangeTurnOrTyping() throws {
        let broker = try makeBroker()
        let chatID = freshChatID()
        let otherID = freshChatID()
        var matching: [String] = []
        var other: [String] = []
        let sub = broker.subscribe(chatID: chatID, registrationProvider: nil) { update in
            if case let .activityStatus(status) = update { matching.append(status) }
        }
        let otherSub = broker.subscribe(chatID: otherID, registrationProvider: nil) { update in
            if case let .activityStatus(status) = update { other.append(status) }
        }
        defer { sub.unsubscribe(); otherSub.unsubscribe() }

        broker.publish(turnEvent: .started, toChatID: chatID)
        broker.publish(activityStatus: "Waiting for approval…", toChatID: chatID)
        broker.publish(activityStatus: "Waiting for approval…", toChatID: chatID)
        XCTAssertEqual(matching, ["Preparing request…", "Waiting for approval…"])
        XCTAssertTrue(other.isEmpty)
        XCTAssertEqual(broker.activityStatus(chatID: chatID), "Waiting for approval…")
        XCTAssertNil(broker.activityStatus(chatID: otherID))
        XCTAssertTrue(TurnStatusModel.instance.inProgress(chatID: chatID))
        XCTAssertFalse(TypingStatusModel.instance.isTyping(participant: .agent, chatID: chatID))

        broker.publish(activityStatus: "Request failed", toChatID: chatID)
        broker.publish(turnEvent: .ended, toChatID: chatID)
        XCTAssertEqual(broker.activityStatus(chatID: chatID), "Request failed")
        XCTAssertFalse(TurnStatusModel.instance.inProgress(chatID: chatID))

        broker.publish(turnEvent: .started, toChatID: chatID)
        broker.publish(turnEvent: .ended, toChatID: chatID)
        XCTAssertEqual(broker.activityStatus(chatID: chatID), "Finished")
    }

    func testSynchronousApprovalDoesNotLeaveWaitingStatus() throws {
        let broker = try makeBroker()
        let chatID = freshChatID()
        let agent = ChatAgent(chatID, broker: broker, mode: .sessionBound,
                              registrationProvider: NoRegistration(), messages: [])
        var completions = 0
        let sub = broker.subscribe(chatID: chatID, registrationProvider: nil) { update in
            guard case .delivery(let message, _, _) = update,
                  case .clientLocal(let local) = message.content,
                  case .enableOrchestrationRequest(let requestID) = local.action else { return }
            agent.handleOrchestrationResponse(requestID: requestID, approved: false)
        }
        defer {
            sub.unsubscribe()
            TypingStatusModel.instance.set(isTyping: false, participant: .agent, chatID: chatID)
        }

        agent.parkOrchestrationRequest { _ in completions += 1 }
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(broker.activityStatus(chatID: chatID), "Resuming AI request…")
        XCTAssertTrue(TypingStatusModel.instance.isTyping(participant: .agent, chatID: chatID))
    }

    func testApprovalStatusClearsOnlyAfterLastPendingRequest() throws {
        let broker = try makeBroker()
        let chatID = freshChatID()
        let agent = ChatAgent(chatID, broker: broker, mode: .sessionBound,
                              registrationProvider: NoRegistration(), messages: [])
        var requestIDs: [String] = []
        let sub = broker.subscribe(chatID: chatID, registrationProvider: nil) { update in
            guard case .delivery(let message, _, _) = update,
                  case .clientLocal(let local) = message.content,
                  case .enableOrchestrationRequest(let requestID) = local.action else { return }
            requestIDs.append(requestID)
        }
        defer {
            sub.unsubscribe()
            TypingStatusModel.instance.set(isTyping: false, participant: .agent, chatID: chatID)
        }

        agent.parkOrchestrationRequest { _ in }
        agent.parkOrchestrationRequest { _ in }
        XCTAssertEqual(requestIDs.count, 2)
        guard requestIDs.count == 2 else { return }
        agent.handleOrchestrationResponse(requestID: requestIDs[0], approved: false)
        XCTAssertEqual(broker.activityStatus(chatID: chatID), "Waiting for approval…")
        XCTAssertFalse(TypingStatusModel.instance.isTyping(participant: .agent, chatID: chatID))
        agent.handleOrchestrationResponse(requestID: requestIDs[1], approved: false)
        XCTAssertEqual(broker.activityStatus(chatID: chatID), "Resuming AI request…")
        XCTAssertTrue(TypingStatusModel.instance.isTyping(participant: .agent, chatID: chatID))
    }

    private func makeRejectedRequest() throws -> (ChatBroker, ChatClient, Chat, UUID, RemoteCommand) {
        let broker = try makeBroker()
        let client = ChatClient(broker: broker)
        let chat = Chat(title: "Denial test", terminalSessionGuid: UUID().uuidString,
                        browserSessionGuid: nil, permissions: "")
        try broker.listModel.add(chat: chat)
        let callID = UUID().uuidString
        let request = RemoteCommand(llmMessage: .init(role: .assistant,
                                                      body: .functionCall(.init(name: "execute_command",
                                                                                arguments: #"{"command":"pwd"}"#,
                                                                                id: callID, thoughtSignature: nil),
                                                                          id: .init(callID: callID, itemID: callID))),
                                    content: .executeCommand(.init(command: "pwd")))
        let requestID = UUID()
        try broker.listModel.append(message: Message(chatID: chat.id, author: .agent,
                                                     content: .remoteCommandRequest(.classic(request), safe: true),
                                                     sentDate: Date(), uniqueID: requestID), toChatID: chat.id)
        return (broker, client, chat, requestID, request)
    }

    func testDenialStopsBeforeRecordingResultAndDoesNotDeliverToolResponse() throws {
        let (broker, client, chat, requestID, request) = try makeRejectedRequest()
        let agent = ChatAgent(chat.id, broker: broker, mode: .sessionBound,
                              registrationProvider: NoRegistration(), messages: [])
        var pendingCompletions = 0
        agent.parkOrchestrationRequest { _ in pendingCompletions += 1 }
        var stops = 0
        var deliveredResults = 0
        let sub = broker.subscribe(chatID: chat.id, registrationProvider: nil) { update in
            guard case .delivery(let message, _, _) = update else { return }
            if case .userCommand(.stop) = message.content {
                stops += 1
                let recorded = broker.listModel.messages(forChat: chat.id, createIfNeeded: false)?.contains {
                    if case .remoteCommandResponse(_, let id, _, _) = $0.content { return id == requestID }
                    return false
                } ?? false
                XCTAssertFalse(recorded, "Stop must precede recording the rejected tool result")
                agent.stop()
            }
            if case .remoteCommandResponse = message.content { deliveredResults += 1 }
        }
        defer {
            sub.unsubscribe()
            TypingStatusModel.instance.set(isTyping: false, participant: .agent, chatID: chat.id)
        }
        try client.rejectRemoteCommandRequest(inChat: chat.id, requestUUID: requestID,
                                              request: request, forRevision: false)
        try client.rejectRemoteCommandRequest(inChat: chat.id, requestUUID: requestID,
                                              request: request, forRevision: false)
        XCTAssertEqual(stops, 1, "A repeated click must not stop a later turn")
        XCTAssertEqual(pendingCompletions, 1, "The rejection must release the parked agent")
        XCTAssertEqual(deliveredResults, 0, "A denial must not resume the tool dispatcher")
        let messages = try XCTUnwrap(broker.listModel.messages(forChat: chat.id, createIfNeeded: false))
        let responses = messages.compactMap { message -> UUID? in
            if case .remoteCommandResponse(_, let id, _, _) = message.content { return id }
            return nil
        }
        XCTAssertEqual(responses, [requestID])
        XCTAssertEqual(broker.activityStatus(chatID: chat.id), "Waiting for your instructions…")
    }

    func testRejectAndReviseRetainsPairingAndInvitesNewInstructions() throws {
        let (broker, client, chat, requestID, request) = try makeRejectedRequest()
        try client.rejectRemoteCommandRequest(inChat: chat.id, requestUUID: requestID,
                                              request: request, forRevision: true)
        let messages = try XCTUnwrap(broker.listModel.messages(forChat: chat.id, createIfNeeded: false))
        var results = 0
        for message in messages {
            if case .remoteCommandResponse(.success(let text), let id, let name, let callID) = message.content {
                results += 1
                XCTAssertEqual(id, requestID)
                XCTAssertEqual(name, "execute_command")
                XCTAssertEqual(callID?.callID, request.llmMessage.functionCallID?.callID)
                XCTAssertTrue(text.contains("wait for approval"))
            }
        }
        XCTAssertEqual(results, 1)
        let rebuilt = ChatViewControllerModel(chatID: chat.id, listModel: broker.listModel)
        XCTAssertNil(rebuilt.items.firstIndex { item in
            guard let message = item.existingMessage?.message else { return false }
            return message.uniqueID == requestID
        }, "Rejected requests must not become approvable again on reload")
    }

    func testApprovalButtonsOfferRejectAndReviseAlongsideExistingChoices() throws {
        let (_, _, chat, requestID, request) = try makeRejectedRequest()
        let message = Message(chatID: chat.id, author: .agent,
                              content: .remoteCommandRequest(.classic(request), safe: true),
                              sentDate: Date(), uniqueID: requestID)
        XCTAssertEqual(message.buttons.map(\.title),
                       ["Allow Once", "Always Allow", "Deny this Time", "Always Deny", "Reject & Revise"])
    }
}
