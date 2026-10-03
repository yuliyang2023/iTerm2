//
//  AIVendorKeyResolutionTests.swift
//  iTerm2 ModernTests
//
//  Pure-unit tests for per-vendor API key resolution and manual-model vendor
//  classification. These cover the regressions where an OpenAI key could be
//  adopted for another vendor, a valid proxied key could be discarded, and the
//  Settings label could disagree with the runtime vendor classification.
//

import AppKit
import XCTest
@testable import iTerm2SharedARC

final class AIVendorKeyResolutionTests: XCTestCase {

    func testManualModelKey_identityIncludesModelEndpointAndProtocol() {
        let account = AITermControllerObjC.manualModelKeychainAccount(
            id: "model-a", url: "https://gateway.example/v1", api: .chatCompletions)
        XCTAssertNotEqual(account, AITermControllerObjC.manualModelKeychainAccount(
            id: "model-b", url: "https://gateway.example/v1", api: .chatCompletions))
        XCTAssertNotEqual(account, AITermControllerObjC.manualModelKeychainAccount(
            id: "model-a", url: "https://other.example/v1", api: .chatCompletions))
        XCTAssertNotEqual(account, AITermControllerObjC.manualModelKeychainAccount(
            id: "model-a", url: "https://gateway.example/v1", api: .responses))
    }

    func testManualModelKey_metadataPreservesCredentialIdentity() throws {
        let saved = iTermPreferences.object(forKey: kPreferenceKeyAIManualModelConfigurations)
        defer { iTermPreferences.setObject(saved, forKey: kPreferenceKeyAIManualModelConfigurations) }
        iTermPreferences.setObject([
            ["id": "test-manual-credential-id", "name": "test-manual-model",
             "url": "https://gateway.example/v1/chat/completions",
             "api": iTermAIAPI.chatCompletions.rawValue],
        ], forKey: kPreferenceKeyAIManualModelConfigurations)
        let model = try XCTUnwrap(LLMMetadata.manualModels().first { $0.name == "test-manual-model" })
        XCTAssertEqual(model.manualCredentialID, "test-manual-credential-id")
    }

    func testManualModelKey_switchingModelsUsesIndependentKeys() throws {
        let url = "http://10.0.0.10/v1/chat/completions"
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        defer {
            _ = AITermControllerObjC.setAPIKey(nil, forManualModelID: firstID, url: url, api: .chatCompletions)
            _ = AITermControllerObjC.setAPIKey(nil, forManualModelID: secondID, url: url, api: .chatCompletions)
        }
        XCTAssertTrue(AITermControllerObjC.setAPIKey("test-model-a", forManualModelID: firstID, url: url, api: .chatCompletions))
        XCTAssertTrue(AITermControllerObjC.setAPIKey("test-model-b", forManualModelID: secondID, url: url, api: .chatCompletions))
        var model = AIMetadata.Model(name: "custom", contextWindowTokens: 8192,
                                    maxResponseTokens: 64, url: url, api: .chatCompletions,
                                    features: [], vendor: .openAI)
        let controller = AITermController(registration: nil)
        model.manualCredentialID = firstID
        controller.providerOverride = LLMProvider(model: model)
        XCTAssertEqual(controller.registration?.apiKey, "test-model-a")
        model.manualCredentialID = secondID
        controller.providerOverride = LLMProvider(model: model)
        XCTAssertEqual(controller.registration?.apiKey, "test-model-b")
        model.url = "http://10.0.0.11/v1/chat/completions"
        XCTAssertNil(AITermControllerObjC.apiKeyForManualModel(model))
        model.url = url
        XCTAssertTrue(AITermControllerObjC.setAPIKey(nil, forManualModelID: secondID, url: url, api: .chatCompletions))
        XCTAssertNil(AITermControllerObjC.apiKeyForManualModel(model))
        XCTAssertEqual(AITermControllerObjC.apiKeyForManualModel(id: firstID, url: url, api: .chatCompletions), "test-model-a")
    }

    func testConnectionTest_usesUnsavedModelKeyAndOmitsUnsupportedTemperature() {
        let completed = expectation(description: "connection tested")
        defer { iTermAIClient.requestInterceptor = nil }
        iTermAIClient.requestInterceptor = { request, _ in
            XCTAssertEqual(request.headers["Authorization"], "Bearer test-unsaved-model-key")
            let body: Data
            switch request.body {
            case .string(let value): body = Data(value.utf8)
            case .bytes(let value): body = Data(value)
            }
            do {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertNil(json["temperature"], "Test Connection must respect Supports temperature")
            } catch {
                XCTFail("Invalid request JSON: \(error)")
            }
            let data = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"Hi"},"finish_reason":"stop"}]}"#
            return iTermAIClient.ReplayDelivery(streamChunks: [], response: WebResponse(data: data, error: nil), errorReason: nil)
        }
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        AIConnectionTester.test(modelName: "custom", url: "http://10.0.0.10/v1/chat/completions",
                                api: .chatCompletions, functionCalling: false,
                                supportsTemperature: false,
                                apiKey: "test-unsaved-model-key", inWindow: window) { outcome, _ in
            XCTAssertEqual(outcome, .success)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
    }

    func testLocalKeyPolicy_defaultsToPlaceholder() {
        for url in ["http://localhost:8080/v1/chat/completions",
                    "https://10.0.0.10/v1/chat/completions",
                    "https://byok.local/v1/chat/completions",
                    "http://[::1]:8080/v1/chat/completions"] {
            XCTAssertTrue(AITermController.usesPlaceholderAPIKey(
                url: url, api: .chatCompletions, trustedLocalHosts: ""), url)
        }
    }

    func testLocalKeyPolicy_trustsOnlyExactHosts() {
        let trusted = "BYOK.LOCAL., 10.0.0.10\n[::1]"
        for url in ["https://byok.local/v1/chat/completions",
                    "https://BYOK.LOCAL.:8443/other-path",
                    "http://10.0.0.10:8080/v1/chat/completions",
                    "http://[::1]:8080/v1/chat/completions"] {
            XCTAssertFalse(AITermController.usesPlaceholderAPIKey(
                url: url, api: .chatCompletions, trustedLocalHosts: trusted), url)
        }
        for url in ["https://other.byok.local/v1/chat/completions",
                    "https://byok.local.evil.local/v1/chat/completions",
                    "https://10.0.0.100/v1/chat/completions"] {
            XCTAssertTrue(AITermController.usesPlaceholderAPIKey(
                url: url, api: .chatCompletions, trustedLocalHosts: trusted), url)
        }
    }

    func testLocalKeyPolicy_doesNotTreatURLsOrWildcardsAsTrustedHosts() {
        for entry in ["https://byok.local", "byok.local:443", "*.local", "byok.local/v1"] {
            XCTAssertTrue(AITermController.usesPlaceholderAPIKey(
                url: "https://byok.local/v1/chat/completions",
                api: .chatCompletions, trustedLocalHosts: entry), entry)
        }
    }

    func testLocalKeyPolicy_preservesPublicAndOnDeviceBehavior() {
        XCTAssertFalse(AITermController.usesPlaceholderAPIKey(
            url: "https://api.openai.com/v1/chat/completions",
            api: .chatCompletions, trustedLocalHosts: ""))
        XCTAssertTrue(AITermController.usesPlaceholderAPIKey(
            url: "http://localhost/v1", api: .appleIntelligence,
            trustedLocalHosts: "localhost"))
    }

    func testLocalKeyPolicy_readsAdvancedSettingForChatAndConnectionTest() {
        let defaults = iTermUserDefaults.userDefaults()
        let saved = defaults.object(forKey: "AiTrustedLocalHosts")
        defer {
            if let saved {
                defaults.set(saved, forKey: "AiTrustedLocalHosts")
            } else {
                defaults.removeObject(forKey: "AiTrustedLocalHosts")
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        defaults.set("byok.local", forKey: "AiTrustedLocalHosts")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        XCTAssertFalse(AITermController.usesPlaceholderAPIKey(
            url: "https://byok.local/v1/chat/completions", api: .chatCompletions))
        defaults.set("", forKey: "AiTrustedLocalHosts")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        XCTAssertTrue(AITermController.usesPlaceholderAPIKey(
            url: "https://byok.local/v1/chat/completions", api: .chatCompletions))
    }

    // MARK: - resolveAPIKey

    func testResolve_trustsVendorAccountKeyVerbatim() {
        // A proxy/gateway token that matches no canonical vendor prefix must
        // still be trusted when it lives in the vendor's own account.
        let result = AITermControllerObjC.resolveAPIKey(
            vendorAccountKey: "sk-or-v1-opaque-proxy-token",
            legacyKey: "sk-legacy-openai",
            vendorUsesLegacyAccount: false,
            vendorIsEffective: false)
        XCTAssertEqual(result,
                       .init(value: "sk-or-v1-opaque-proxy-token",
                             migrateLegacyToVendorAccount: false))
    }

    func testResolve_adoptsLegacyKeyOnlyForEffectiveVendor() {
        let result = AITermControllerObjC.resolveAPIKey(
            vendorAccountKey: nil,
            legacyKey: "sk-legacy-openai",
            vendorUsesLegacyAccount: false,
            vendorIsEffective: true)
        XCTAssertEqual(result,
                       .init(value: "sk-legacy-openai",
                             migrateLegacyToVendorAccount: true))
    }

    func testResolve_doesNotAdoptLegacyKeyForNonEffectiveVendor() {
        // This is the cross-contamination bug: an OpenAI legacy key must NOT be
        // handed to (e.g.) DeepSeek/Llama just because its text is ambiguous.
        let result = AITermControllerObjC.resolveAPIKey(
            vendorAccountKey: nil,
            legacyKey: "sk-legacy-openai",
            vendorUsesLegacyAccount: false,
            vendorIsEffective: false)
        XCTAssertEqual(result, .init(value: nil, migrateLegacyToVendorAccount: false))
    }

    func testResolve_ignoresEmptyLegacyKey() {
        let result = AITermControllerObjC.resolveAPIKey(
            vendorAccountKey: nil,
            legacyKey: "   ",
            vendorUsesLegacyAccount: false,
            vendorIsEffective: true)
        XCTAssertEqual(result, .init(value: nil, migrateLegacyToVendorAccount: false))
    }

    func testResolve_openAIUsesLegacyAccountDoesNotDoubleMigrate() {
        // When the vendor's account IS the legacy account (OpenAI), the stored
        // value already comes through vendorAccountKey; there is nothing to
        // migrate.
        let result = AITermControllerObjC.resolveAPIKey(
            vendorAccountKey: nil,
            legacyKey: nil,
            vendorUsesLegacyAccount: true,
            vendorIsEffective: true)
        XCTAssertEqual(result, .init(value: nil, migrateLegacyToVendorAccount: false))
    }

    // MARK: - vendor(forModelName:)

    func testVendorForModelName_recognizesRetiredModels() {
        XCTAssertEqual(LLMMetadata.vendor(forModelName: "claude-opus-4-1"), .anthropic)
        XCTAssertEqual(LLMMetadata.vendor(forModelName: "claude-sonnet-4-0"), .anthropic)
        XCTAssertEqual(LLMMetadata.vendor(forModelName: "gemini-3-pro-preview"), .gemini)
        XCTAssertEqual(LLMMetadata.vendor(forModelName: "gemini-2.0-flash"), .gemini)
        XCTAssertEqual(LLMMetadata.vendor(forModelName: "deepseek-chat"), .deepSeek)
        XCTAssertEqual(LLMMetadata.vendor(forModelName: "llama4:latest"), .llama)
    }

    func testVendorForModelName_returnsNilWhenNoVendorKeyword() {
        XCTAssertNil(LLMMetadata.vendor(forModelName: "gpt-5"))
        XCTAssertNil(LLMMetadata.vendor(forModelName: "my-local-model"))
    }

    // A retired model must resolve to a still-existing recommended model of the
    // SAME vendor, so a chat pinned to it does not silently switch providers.
    func testRetiredModelKeepsSameVendor() throws {
        for name in ["claude-sonnet-4-0", "gemini-1.5-pro"] {
            guard AIMetadata.instance.models.first(where: { $0.name == name }) == nil else {
                XCTFail("\(name) is still present; update this retirement test")
                continue
            }
            let vendor = try XCTUnwrap(LLMMetadata.vendor(forModelName: name))
            let replacement = try XCTUnwrap(LLMMetadata.recommendedModel(for: vendor)
                                            ?? LLMMetadata.alternateModels(for: vendor).first,
                                            "No same-vendor replacement for \(name)")
            XCTAssertEqual(replacement.vendor, vendor)
        }
    }

    // MARK: - manual-model vendor classification (Settings label == runtime)

    func testManualVendor_localhostIsNotMisclassifiedAsLlama() {
        // The runtime resolver has no localhost=>Llama rule; the Settings UI now
        // routes through this same resolver so its label agrees with routing.
        let vendor = LLMMetadata.objcManualVendor(api: .chatCompletions,
                                                  url: "http://localhost:8080/v1",
                                                  modelName: "my-local-model")
        XCTAssertEqual(vendor, .openAI)
    }

    func testManualVendor_apiSelectsVendor() {
        XCTAssertEqual(LLMMetadata.objcManualVendor(api: .anthropic,
                                                    url: "",
                                                    modelName: "whatever"),
                       .anthropic)
        XCTAssertEqual(LLMMetadata.objcManualVendor(api: .gemini,
                                                    url: "",
                                                    modelName: "whatever"),
                       .gemini)
    }

    func testManualVendor_nameAndHostHeuristics() {
        XCTAssertEqual(LLMMetadata.objcManualVendor(api: .chatCompletions,
                                                    url: "https://example.com",
                                                    modelName: "claude-custom"),
                       .anthropic)
        XCTAssertEqual(LLMMetadata.objcManualVendor(api: .chatCompletions,
                                                    url: "https://api.anthropic.com/v1",
                                                    modelName: "custom"),
                       .anthropic)
        XCTAssertEqual(LLMMetadata.objcManualVendor(api: .chatCompletions,
                                                    url: "https://api.openai.com/v1",
                                                    modelName: "custom"),
                       .openAI)
    }
}
