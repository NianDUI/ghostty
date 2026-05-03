import AppKit
import Foundation
import Testing
@testable import Ghostty

@Suite
struct SessionSharingTests {
    @Test
    func reconnectPolicyBackoffSequence() {
        var policy = SessionSharingReconnectPolicy()
        let delays = (0..<7).map { _ in policy.nextDelay() }

        #expect(delays == [1, 2, 4, 8, 16, 30, 30])
        #expect(policy.attempt == 7)
    }

    @Test
    func reconnectPolicyResetRestartsSequence() {
        var policy = SessionSharingReconnectPolicy()
        _ = policy.nextDelay()
        _ = policy.nextDelay()

        policy.reset()

        #expect(policy.attempt == 0)
        #expect(policy.nextDelay() == 1)
    }

    @Test
    func sharingStateDerivedPresentation() {
        #expect(Ghostty.OSSurfaceView.SharingState.idle.statusText == nil)
        #expect(Ghostty.OSSurfaceView.SharingState.idle.titleSuffix == "")
        #expect(Ghostty.OSSurfaceView.SharingState.idle.isActive == false)

        #expect(Ghostty.OSSurfaceView.SharingState.sharing.statusText == "共享中")
        #expect(Ghostty.OSSurfaceView.SharingState.sharing.titleSuffix == " [共享中]")
        #expect(Ghostty.OSSurfaceView.SharingState.sharing.isActive == true)

        #expect(Ghostty.OSSurfaceView.SharingState.reconnecting.statusText == "重连中...")
        #expect(Ghostty.OSSurfaceView.SharingState.error("x").isActive == false)
    }

    @Test
    func configStoreSaveLoadRoundTripAndPermissions() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }

        let fileURL = sandbox.root
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("sharing.conf", isDirectory: false)
        let store = SessionSharingConfigStore(
            fileURL: fileURL,
            keychainTokenReader: { _, _ in nil },
            logError: { _ in }
        )
        let config = SessionSharingPersistedConfig(
            relay: "relay.example.com:443",
            token: "secret-token",
            relayHistory: ["relay.example.com:443", "relay.backup:443"],
            lastSessionName: "Ghostty-20260502-120000"
        )

        #expect(store.save(config) == true)
        let loaded = store.load()

        #expect(loaded == config)

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)
    }

    @Test
    func configStoreDropsTokenWhenPermissionsAreTooOpen() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }

        let fileURL = sandbox.root
            .appendingPathComponent("sharing.conf", isDirectory: false)
        let config = SessionSharingPersistedConfig(
            relay: "relay.example.com:443",
            token: "secret-token",
            relayHistory: ["relay.example.com:443"],
            lastSessionName: "Ghostty-20260502-120000"
        )
        try JSONEncoder().encode(config).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

        let store = SessionSharingConfigStore(
            fileURL: fileURL,
            keychainTokenReader: { _, _ in nil },
            logError: { _ in }
        )
        let loaded = store.load()

        #expect(loaded.relay == config.relay)
        #expect(loaded.relayHistory == config.relayHistory)
        #expect(loaded.lastSessionName == config.lastSessionName)
        #expect(loaded.token == nil)
    }

    @Test
    func configStoreHistoryDeduplicatesAndCapsAtEight() {
        let store = SessionSharingConfigStore(
            fileURL: URL(fileURLWithPath: "/tmp/ghostty-sharing-test"),
            keychainTokenReader: { _, _ in nil },
            logError: { _ in }
        )

        let updated = store.updatedHistory("relay-9", existing: [
            "relay-1", "relay-2", "relay-3", "relay-4",
            "relay-5", "relay-6", "relay-7", "relay-8", "relay-9",
        ])

        #expect(updated == [
            "relay-9", "relay-1", "relay-2", "relay-3",
            "relay-4", "relay-5", "relay-6", "relay-7",
        ])
    }

    @Test
    func configStoreCanUseInjectedKeychainReader() {
        let store = SessionSharingConfigStore(
            fileURL: URL(fileURLWithPath: "/tmp/ghostty-sharing-test"),
            keychainTokenReader: { service, relay in
                #expect(service == "com.mitchellh.ghostty.session-sharing")
                return relay == "relay.example.com:443" ? "keychain-token" : nil
            },
            logError: { _ in }
        )

        #expect(store.readKeychainToken(forRelay: "relay.example.com:443") == "keychain-token")
        #expect(store.readKeychainToken(forRelay: "other.example.com:443") == "")
    }

    @Test
    func relayURLBuilderAddsSchemeAndPath() throws {
        let url = try SessionSharingRelayURLBuilder.url(
            for: "relay.example.com:443",
            scheme: "https",
            path: "/api/register"
        )

        #expect(url.absoluteString == "https://relay.example.com:443/api/register")
    }

    @Test
    func relayURLBuilderOverridesInputSchemeAndAddsQuery() throws {
        let url = try SessionSharingRelayURLBuilder.url(
            for: "https://relay.example.com:8443/base",
            scheme: "wss",
            path: "/ws/agent",
            queryItems: [URLQueryItem(name: "id", value: "abc-123")]
        )

        #expect(url.absoluteString == "wss://relay.example.com:8443/ws/agent?id=abc-123")
    }

    @Test
    func relayURLBuilderPreservesExplicitInsecureSchemeForLocalDevelopment() throws {
        let registerURL = try SessionSharingRelayURLBuilder.url(
            for: "http://127.0.0.1:8080",
            scheme: "https",
            path: "/api/register"
        )
        let webSocketURL = try SessionSharingRelayURLBuilder.url(
            for: "http://127.0.0.1:8080",
            scheme: "wss",
            path: "/ws/agent",
            queryItems: [URLQueryItem(name: "id", value: "abc-123")]
        )

        #expect(registerURL.absoluteString == "http://127.0.0.1:8080/api/register")
        #expect(webSocketURL.absoluteString == "ws://127.0.0.1:8080/ws/agent?id=abc-123")
    }

    @Test
    func relayURLBuilderRejectsEmptyRelay() {
        #expect(throws: SessionSharingError.invalidRelayAddress) {
            _ = try SessionSharingRelayURLBuilder.url(
                for: "   ",
                scheme: "https",
                path: "/api/register"
            )
        }
    }

    @Test
    func relayURLBuilderRejectsMalformedRelay() {
        #expect(throws: SessionSharingError.invalidRelayAddress) {
            _ = try SessionSharingRelayURLBuilder.url(
                for: "https://",
                scheme: "https",
                path: "/api/register"
            )
        }
    }

    @Test
    func lifecycleDisconnectRequestsReconnectWhenAllowed() {
        let transition = SessionSharingLifecycle.transitionAfterDisconnect(
            shouldReconnect: true,
            isStopping: false
        )

        #expect(transition == .reconnect)
    }

    @Test
    func lifecycleDisconnectStopsWhenReconnectDisabled() {
        let transition = SessionSharingLifecycle.transitionAfterDisconnect(
            shouldReconnect: false,
            isStopping: false
        )

        #expect(transition == .idle)
    }

    @Test
    func lifecycleDisconnectStopsWhenControllerIsStopping() {
        let transition = SessionSharingLifecycle.transitionAfterDisconnect(
            shouldReconnect: true,
            isStopping: true
        )

        #expect(transition == .idle)
    }

    @Test
    func lifecycleStopStateDependsOnUserInitiation() {
        #expect(SessionSharingLifecycle.stateAfterStop(userInitiated: true) == .idle)
        #expect(SessionSharingLifecycle.stateAfterStop(userInitiated: false) == .error("共享已停止"))
    }

    @Test
    func lifecycleOnlyPresentsInitialConnectFailure() {
        #expect(SessionSharingLifecycle.shouldPresentConnectFailure(initialAttempt: true) == true)
        #expect(SessionSharingLifecycle.shouldPresentConnectFailure(initialAttempt: false) == false)
    }

    @Test
    func menuPresentationForInactiveSurface() {
        let presentation = SessionSharingMenuPresentation(
            hasFocusedSurface: true,
            hasLiveSurface: true,
            sharingState: .idle
        )

        #expect(presentation.title == "共享此会话")
        #expect(presentation.isEnabled == true)
    }

    @Test
    func menuPresentationForActiveSharedSurface() {
        let presentation = SessionSharingMenuPresentation(
            hasFocusedSurface: true,
            hasLiveSurface: true,
            sharingState: .sharing
        )

        #expect(presentation.title == "停止共享")
        #expect(presentation.isEnabled == true)
    }

    @Test
    func keyEquivalentPolicyAllowsFieldEditorsToUseStandardResponderChain() {
        let fieldEditor = NSTextView()
        fieldEditor.isFieldEditor = true

        #expect(
            SessionSharingKeyEquivalentPolicy.shouldUseStandardResponderChain(
                firstResponder: fieldEditor
            ) == true
        )
        #expect(
            SessionSharingKeyEquivalentPolicy.shouldUseStandardResponderChain(
                firstResponder: NSView()
            ) == false
        )
        #expect(
            SessionSharingKeyEquivalentPolicy.shouldUseStandardResponderChain(
                firstResponder: nil
            ) == false
        )
    }

    @Test
    func menuPresentationDisabledWithoutFocusedSurface() {
        let presentation = SessionSharingMenuPresentation(
            hasFocusedSurface: false,
            hasLiveSurface: false,
            sharingState: .idle
        )

        #expect(presentation.title == "共享此会话")
        #expect(presentation.isEnabled == false)
    }

    @Test
    func menuPresentationDisabledWhenSurfaceIsGone() {
        let presentation = SessionSharingMenuPresentation(
            hasFocusedSurface: true,
            hasLiveSurface: false,
            sharingState: .reconnecting
        )

        #expect(presentation.title == "停止共享")
        #expect(presentation.isEnabled == false)
    }

    @Test
    func inboundFrameActionForPingRequestsPong() {
        let action = SessionSharingInboundFrameAction.parse(
            text: #"{"type":"ping"}"#,
            sessionID: "session-123"
        )

        #expect(action == .sendPong(.pong(id: "session-123")))
    }

    @Test
    func inboundFrameActionForResizeRequestsSharedResize() {
        let action = SessionSharingInboundFrameAction.parse(
            text: #"{"type":"resize","cols":120,"rows":30}"#,
            sessionID: "session-123"
        )

        #expect(action == .resize(cols: 120, rows: 30))
    }

    @Test
    func inboundFrameActionForPongIsIgnored() {
        let action = SessionSharingInboundFrameAction.parse(
            text: #"{"type":"pong","id":"session-123"}"#,
            sessionID: "session-123"
        )

        #expect(action == .ignore)
    }

    @Test
    func inboundFrameActionForUnknownControlFallsBackToTerminal() {
        let action = SessionSharingInboundFrameAction.parse(
            text: #"{"type":"custom"}"#,
            sessionID: "session-123"
        )

        #expect(action == .forwardToTerminal)
    }

    @Test
    func inboundFrameActionForInvalidJsonFallsBackToTerminal() {
        let action = SessionSharingInboundFrameAction.parse(
            text: "plain terminal text",
            sessionID: "session-123"
        )

        #expect(action == .forwardToTerminal)
    }

    @Test
    func registerRequestUsesExpectedMethodHeadersAndBody() throws {
        let payload = SessionSharingRegisterRequest(
            sessionID: "session-123",
            name: "Ghostty-20260502-120000",
            token: "user-token"
        )
        let request = try SessionSharingRequestBuilder.registerRequest(
            relayAddress: "relay.example.com:443",
            payload: payload
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://relay.example.com:443/api/register")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let decoded = try JSONDecoder().decode(SessionSharingRegisterRequest.self, from: body)
        #expect(decoded == payload)
    }

    @Test
    func agentWebSocketRequestUsesExpectedUrlAndAuthorization() throws {
        let request = try SessionSharingRequestBuilder.agentWebSocketRequest(
            relayAddress: "https://relay.example.com:8443/base",
            sessionID: "session-123",
            agentToken: "agent-token"
        )

        #expect(request.url?.absoluteString == "wss://relay.example.com:8443/ws/agent?id=session-123")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer agent-token")
    }

    @Test
    func requestsRespectExplicitHttpRelayForLocalDevelopment() throws {
        let payload = SessionSharingRegisterRequest(
            sessionID: "session-123",
            name: "Ghostty-20260502-120000",
            token: "user-token"
        )
        let registerRequest = try SessionSharingRequestBuilder.registerRequest(
            relayAddress: "http://127.0.0.1:8080",
            payload: payload
        )
        let webSocketRequest = try SessionSharingRequestBuilder.agentWebSocketRequest(
            relayAddress: "http://127.0.0.1:8080",
            sessionID: "session-123",
            agentToken: "agent-token"
        )

        #expect(registerRequest.url?.absoluteString == "http://127.0.0.1:8080/api/register")
        #expect(webSocketRequest.url?.absoluteString == "ws://127.0.0.1:8080/ws/agent?id=session-123")
    }

    @Test
    func registerResponseParserAcceptsExpectedPayload() throws {
        let response = HTTPURLResponse(
            url: try #require(URL(string: "https://relay.example.com/api/register")),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let payload = SessionSharingRegisterResponse(
            sessionID: "session-123",
            agentToken: "agent-token",
            clientToken: "client-token",
            expiresAt: "2026-05-02T06:00:00Z"
        )
        let data = try JSONEncoder().encode(payload)

        let parsed = try SessionSharingResponseParser.parseRegisterResponse(
            data: data,
            response: response,
            expectedSessionID: "session-123"
        )

        #expect(parsed == payload)
    }

    @Test
    func registerResponseParserRejectsNonSuccessStatus() throws {
        let response = HTTPURLResponse(
            url: try #require(URL(string: "https://relay.example.com/api/register")),
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!
        let data = try JSONEncoder().encode(SessionSharingRegisterResponse(
            sessionID: "session-123",
            agentToken: "agent-token",
            clientToken: nil,
            expiresAt: nil
        ))

        #expect(throws: SessionSharingError.invalidResponse) {
            _ = try SessionSharingResponseParser.parseRegisterResponse(
                data: data,
                response: response,
                expectedSessionID: "session-123"
            )
        }
    }

    @Test
    func registerResponseParserRejectsEmptyAgentToken() throws {
        let response = HTTPURLResponse(
            url: try #require(URL(string: "https://relay.example.com/api/register")),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let data = try JSONEncoder().encode(SessionSharingRegisterResponse(
            sessionID: "session-123",
            agentToken: "",
            clientToken: nil,
            expiresAt: nil
        ))

        #expect(throws: SessionSharingError.invalidResponse) {
            _ = try SessionSharingResponseParser.parseRegisterResponse(
                data: data,
                response: response,
                expectedSessionID: "session-123"
            )
        }
    }

    @Test
    func registerResponseParserRejectsMismatchedSessionID() throws {
        let response = HTTPURLResponse(
            url: try #require(URL(string: "https://relay.example.com/api/register")),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let data = try JSONEncoder().encode(SessionSharingRegisterResponse(
            sessionID: "session-456",
            agentToken: "agent-token",
            clientToken: nil,
            expiresAt: nil
        ))

        #expect(throws: SessionSharingError.invalidResponse) {
            _ = try SessionSharingResponseParser.parseRegisterResponse(
                data: data,
                response: response,
                expectedSessionID: "session-123"
            )
        }
    }
}

private struct TestSandbox {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-session-sharing-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
