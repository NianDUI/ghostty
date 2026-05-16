import AppKit
import Foundation
import Testing
@testable import Ghostty

@Suite
struct SessionSharingTests {
    private struct StubNetworkClient: SessionSharingNetworkClient {
        let dataHandler: @Sendable (URLRequest) async throws -> (Data, URLResponse)
        let webSocketHandler: @Sendable (URLRequest) -> URLSessionWebSocketTask

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try await dataHandler(request)
        }

        func webSocketTask(with request: URLRequest) -> URLSessionWebSocketTask {
            webSocketHandler(request)
        }
    }

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

        // Immediate retry (relay's 4401 token-expired fast-path passes 0)
        // keeps the original "重连中..." label so we don't claim a delay
        // that isn't there.
        #expect(
            Ghostty.OSSurfaceView.SharingState.reconnecting(after: 0).statusText == "重连中..."
        )
        // A scheduled reconnect surfaces the actual delay so the user
        // can tell that nothing's hung — they're just waiting for the
        // backoff window. Sub-second delays round to 0 and fall back
        // to the "..." label.
        #expect(
            Ghostty.OSSurfaceView.SharingState.reconnecting(after: 5).statusText == "重连中（5s 后）"
        )
        #expect(
            Ghostty.OSSurfaceView.SharingState.reconnecting(after: 30).statusText == "重连中（30s 后）"
        )
        #expect(
            Ghostty.OSSurfaceView.SharingState.reconnecting(after: 0.4).statusText == "重连中..."
        )
        #expect(
            Ghostty.OSSurfaceView.SharingState.reconnecting(after: 5).isActive == true
        )
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
    func configStoreWriteKeychainTokenForwardsServiceAccountAndValue() {
        var captured: [(service: String, account: String, token: String)] = []
        let store = SessionSharingConfigStore(
            fileURL: URL(fileURLWithPath: "/tmp/ghostty-sharing-test"),
            keychainTokenReader: { _, _ in nil },
            keychainTokenWriter: { service, account, token in
                captured.append((service: service, account: account, token: token))
                return true
            },
            logError: { _ in }
        )

        let result = store.writeKeychainToken("opaque-bearer", forRelay: "relay.example.com:443")

        #expect(result == true)
        #expect(captured.count == 1)
        #expect(captured.first?.service == "com.mitchellh.ghostty.session-sharing")
        #expect(captured.first?.account == "relay.example.com:443")
        #expect(captured.first?.token == "opaque-bearer")
    }

    @Test
    func configStoreWriteKeychainTokenSkipsEmptyTokenOrRelay() {
        var calls = 0
        let store = SessionSharingConfigStore(
            fileURL: URL(fileURLWithPath: "/tmp/ghostty-sharing-test"),
            keychainTokenReader: { _, _ in nil },
            keychainTokenWriter: { _, _, _ in
                calls += 1
                return true
            },
            logError: { _ in }
        )

        #expect(store.writeKeychainToken("", forRelay: "relay") == false)
        #expect(store.writeKeychainToken("token", forRelay: "") == false)
        #expect(store.writeKeychainToken("", forRelay: "") == false)
        #expect(calls == 0)
    }

    @Test
    func configStoreSaveMirrorsTokenToKeychain() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        var captured: [(service: String, account: String, token: String)] = []
        let store = SessionSharingConfigStore(
            fileURL: sandbox.root.appendingPathComponent("sharing.conf"),
            keychainTokenReader: { _, _ in nil },
            keychainTokenWriter: { service, account, token in
                captured.append((service: service, account: account, token: token))
                return true
            },
            logError: { _ in }
        )

        let saved = store.save(
            SessionSharingPersistedConfig(
                relay: "relay.example.com:443",
                token: "opaque-bearer",
                relayHistory: ["relay.example.com:443"],
                lastSessionName: "demo"
            )
        )

        #expect(saved == true)
        #expect(captured.count == 1)
        #expect(captured.first?.account == "relay.example.com:443")
        #expect(captured.first?.token == "opaque-bearer")
    }

    @Test
    func configStoreSaveSkipsKeychainWhenTokenOrRelayMissing() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        var calls = 0
        let store = SessionSharingConfigStore(
            fileURL: sandbox.root.appendingPathComponent("sharing.conf"),
            keychainTokenReader: { _, _ in nil },
            keychainTokenWriter: { _, _, _ in
                calls += 1
                return true
            },
            logError: { _ in }
        )

        // Missing token: don't write a row with an empty value.
        _ = store.save(
            SessionSharingPersistedConfig(
                relay: "relay.example.com:443",
                token: nil,
                relayHistory: [],
                lastSessionName: nil
            )
        )
        // Missing relay: nothing to scope the Keychain account on.
        _ = store.save(
            SessionSharingPersistedConfig(
                relay: nil,
                token: "opaque-bearer",
                relayHistory: [],
                lastSessionName: nil
            )
        )
        #expect(calls == 0)
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
    func relayURLBuilderRejectsExplicitInsecureRemoteRelay() {
        #expect(throws: SessionSharingError.insecureRelayAddress) {
            _ = try SessionSharingRelayURLBuilder.url(
                for: "http://relay.example.com:8080",
                scheme: "https",
                path: "/api/register"
            )
        }
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
    func sheetValidationRejectsExplicitInsecureRemoteRelay() {
        #expect(
            SessionSharingSheetValidation.message(
                name: "Ghostty-20260503-120000",
                relay: "http://relay.example.com:8080",
                token: "token"
            ) == SessionSharingError.insecureRelayAddress.localizedDescription
        )
    }

    @Test
    func sheetValidationRequiresCompleteFields() {
        #expect(
            SessionSharingSheetValidation.message(
                name: "",
                relay: "127.0.0.1:18080",
                token: "token"
            ) == "共享配置不完整"
        )
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
    func controllerRecoveryInitialConnectFailurePresentsErrorAndSchedulesReconnect() {
        var policy = SessionSharingReconnectPolicy()
        let plan = SessionSharingControllerRecovery.connectFailurePlan(
            initialAttempt: true,
            shouldReconnect: true,
            isStopping: false,
            reconnectPolicy: &policy
        )

        #expect(plan.shouldPresentError == true)
        #expect(plan.action == .reconnect(after: 1))
        #expect(policy.attempt == 1)
    }

    @Test
    func controllerRecoveryReconnectFailureSkipsErrorAndAdvancesBackoff() {
        var policy = SessionSharingReconnectPolicy()
        _ = SessionSharingControllerRecovery.connectFailurePlan(
            initialAttempt: true,
            shouldReconnect: true,
            isStopping: false,
            reconnectPolicy: &policy
        )

        let plan = SessionSharingControllerRecovery.connectFailurePlan(
            initialAttempt: false,
            shouldReconnect: true,
            isStopping: false,
            reconnectPolicy: &policy
        )

        #expect(plan.shouldPresentError == false)
        #expect(plan.action == .reconnect(after: 2))
        #expect(policy.attempt == 2)
    }

    @Test
    func controllerRecoveryDoesNotScheduleReconnectWhenDisabled() {
        var policy = SessionSharingReconnectPolicy()
        let plan = SessionSharingControllerRecovery.connectFailurePlan(
            initialAttempt: true,
            shouldReconnect: false,
            isStopping: false,
            reconnectPolicy: &policy
        )

        #expect(plan.shouldPresentError == true)
        #expect(plan.action == .idle)
        #expect(policy.attempt == 0)
    }

    @Test
    func controllerRecoveryDisconnectActionAdvancesBackoffOnlyWhenReconnects() {
        var policy = SessionSharingReconnectPolicy()
        let first = SessionSharingControllerRecovery.disconnectAction(
            closeCode: 0,
            shouldReconnect: true,
            isStopping: false,
            reconnectPolicy: &policy
        )
        let second = SessionSharingControllerRecovery.disconnectAction(
            closeCode: 0,
            shouldReconnect: true,
            isStopping: false,
            reconnectPolicy: &policy
        )
        let stopped = SessionSharingControllerRecovery.disconnectAction(
            closeCode: 0,
            shouldReconnect: true,
            isStopping: true,
            reconnectPolicy: &policy
        )

        #expect(first == .reconnect(after: 1))
        #expect(second == .reconnect(after: 2))
        #expect(stopped == .idle)
        #expect(policy.attempt == 2)
    }

    @Test
    func controllerRecoveryDisconnectAction4401TokenExpiredResetsBackoff() {
        var policy = SessionSharingReconnectPolicy()
        // Build up some backoff history first.
        _ = SessionSharingControllerRecovery.disconnectAction(
            closeCode: 0,
            shouldReconnect: true,
            isStopping: false,
            reconnectPolicy: &policy
        )
        _ = SessionSharingControllerRecovery.disconnectAction(
            closeCode: 0,
            shouldReconnect: true,
            isStopping: false,
            reconnectPolicy: &policy
        )
        #expect(policy.attempt == 2)

        // Now a token-expired close: skip the backoff entirely and clear
        // the prior attempt history, since the relay told us those
        // attempts were against an expired session that's now gone.
        let action = SessionSharingControllerRecovery.disconnectAction(
            closeCode: SessionSharingCloseCode.tokenExpired,
            shouldReconnect: true,
            isStopping: false,
            reconnectPolicy: &policy
        )

        #expect(action == .reconnect(after: 0))
        #expect(policy.attempt == 0)
    }

    @Test
    func controllerRecoveryDisconnectAction4408TimeoutKeepsBackoff() {
        // The heartbeat-timeout / slow-consumer code is a transient
        // signal; reconnect with the normal exponential backoff so a
        // flaky network doesn't get an immediate retry storm.
        var policy = SessionSharingReconnectPolicy()
        _ = SessionSharingControllerRecovery.disconnectAction(
            closeCode: 0,
            shouldReconnect: true,
            isStopping: false,
            reconnectPolicy: &policy
        )
        let action = SessionSharingControllerRecovery.disconnectAction(
            closeCode: SessionSharingCloseCode.timeoutOrSlow,
            shouldReconnect: true,
            isStopping: false,
            reconnectPolicy: &policy
        )

        #expect(action == .reconnect(after: 2))
        #expect(policy.attempt == 2)
    }

    @Test
    func controllerRecovery4401IsIgnoredWhenReconnectsDisabled() {
        // shouldReconnect=false means the user asked us to stop. Even a
        // token_expired close shouldn't surprise them with a fresh
        // connection attempt.
        var policy = SessionSharingReconnectPolicy()
        let action = SessionSharingControllerRecovery.disconnectAction(
            closeCode: SessionSharingCloseCode.tokenExpired,
            shouldReconnect: false,
            isStopping: false,
            reconnectPolicy: &policy
        )

        #expect(action == .idle)
        #expect(policy.attempt == 0)
    }

    @Test
    func reconnectCoordinatorFirstScheduleDoesNotCancelExistingWork() {
        var coordinator = SessionSharingReconnectCoordinator()
        let plan = coordinator.prepareToSchedule(after: 4)

        #expect(plan == .init(delay: 4, shouldCancelExisting: false))
        #expect(coordinator.hasScheduledReconnect == true)
    }

    @Test
    func reconnectCoordinatorSecondScheduleReplacesExistingWork() {
        var coordinator = SessionSharingReconnectCoordinator()
        _ = coordinator.prepareToSchedule(after: 1)

        let plan = coordinator.prepareToSchedule(after: 8)

        #expect(plan == .init(delay: 8, shouldCancelExisting: true))
        #expect(coordinator.hasScheduledReconnect == true)
    }

    @Test
    func reconnectCoordinatorCancelOnlySucceedsWhenPendingReconnectExists() {
        var coordinator = SessionSharingReconnectCoordinator()
        #expect(coordinator.cancelScheduledReconnect() == false)

        _ = coordinator.prepareToSchedule(after: 2)

        #expect(coordinator.cancelScheduledReconnect() == true)
        #expect(coordinator.hasScheduledReconnect == false)
        #expect(coordinator.cancelScheduledReconnect() == false)
    }

    @Test
    func reconnectCoordinatorMarksReconnectAsFired() {
        var coordinator = SessionSharingReconnectCoordinator()
        _ = coordinator.prepareToSchedule(after: 2)

        coordinator.markReconnectFired()

        #expect(coordinator.hasScheduledReconnect == false)
    }

    @Test
    func reconnectSchedulerUsesInjectedScheduleClosureAndCancelableTask() {
        let lock = NSLock()
        var recordedDelay: TimeInterval?
        var cancelCount = 0
        let scheduler = SessionSharingReconnectScheduler { delay, _ in
            lock.lock()
            recordedDelay = delay
            lock.unlock()
            return SessionSharingScheduledTask {
                lock.lock()
                cancelCount += 1
                lock.unlock()
            }
        }

        let task = scheduler.schedule(after: 5) {}
        task.cancel()

        lock.lock()
        defer { lock.unlock() }
        #expect(recordedDelay == 5)
        #expect(cancelCount == 1)
    }

    @Test
    func outputBridgeUsesInjectedAttachAndDetachClosures() {
        let lock = NSLock()
        var attachCalls = 0
        var detachCalls = 0
        let bridge = SessionSharingOutputBridge(
            attach: { _, _ in
                lock.lock()
                attachCalls += 1
                lock.unlock()
            },
            detach: { _ in
                lock.lock()
                detachCalls += 1
                lock.unlock()
            }
        )

        bridge.attach(surface: nil, context: nil)
        bridge.detach(surface: nil)

        lock.lock()
        defer { lock.unlock() }
        #expect(attachCalls == 1)
        #expect(detachCalls == 1)
    }

    @Test
    func controllerDependenciesCarryInjectedCollaborators() async throws {
        let expectedURL = try #require(URL(string: "https://relay.example.com/api/register"))
        let expectedResponse = try #require(HTTPURLResponse(
            url: expectedURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let expectedData = Data("ok".utf8)
        let request = URLRequest(url: expectedURL)
        let webSocketTask = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "wss://relay.example.com/ws/agent")!)
        let network = StubNetworkClient(
            dataHandler: { incomingRequest in
                #expect(incomingRequest.url == expectedURL)
                return (expectedData, expectedResponse)
            },
            webSocketHandler: { incomingRequest in
                #expect(incomingRequest.url?.absoluteString == "wss://relay.example.com/ws/agent")
                return webSocketTask
            }
        )
        let dependencies = SessionSharingControllerDependencies(
            networkClient: network,
            outputBridge: SessionSharingOutputBridge(
                attach: { _, _ in },
                detach: { _ in }
            ),
            reconnectScheduler: .live()
        )

        let (data, response) = try await dependencies.networkClient.data(for: request)
        let task = dependencies.networkClient.webSocketTask(
            with: URLRequest(url: try #require(URL(string: "wss://relay.example.com/ws/agent")))
        )

        #expect(data == expectedData)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(task == webSocketTask)
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
                firstResponder: NSView(),
                hasAttachedSheet: true
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
    func editActionPolicyWalksTheResponderChain() {
        let fieldEditor = NSTextView()
        fieldEditor.isFieldEditor = true
        let intermediate = NSView()
        intermediate.nextResponder = fieldEditor
        let excluded = NSView()
        excluded.nextResponder = intermediate

        // Starts from a non-text view, walks past it to the field editor that handles `paste:`.
        let handler = SessionSharingEditActionPolicy.handler(
            for: #selector(NSText.paste(_:)),
            startingAt: excluded
        )
        #expect(handler === fieldEditor)

        // The `excluding` parameter prevents the surface view from being re-entered.
        let skipped = SessionSharingEditActionPolicy.handler(
            for: #selector(NSText.paste(_:)),
            startingAt: excluded,
            excluding: excluded
        )
        #expect(skipped === fieldEditor)

        // No handler exists when the chain is empty.
        #expect(
            SessionSharingEditActionPolicy.handler(
                for: #selector(NSText.paste(_:)),
                startingAt: nil
            ) == nil
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
    func inboundFrameActionForClientDisconnectRestoresOriginalSize() {
        let action = SessionSharingInboundFrameAction.parse(
            text: #"{"type":"client_disconnect"}"#,
            sessionID: "session-123"
        )

        #expect(action == .restoreOriginalSize)
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
    func registerResponseParserMaps401ToUserTokenRejected() throws {
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

        #expect(throws: SessionSharingError.userTokenRejected) {
            _ = try SessionSharingResponseParser.parseRegisterResponse(
                data: data,
                response: response,
                expectedSessionID: "session-123"
            )
        }
    }

    @Test
    func registerResponseParserRejectsOtherNonSuccessStatus() throws {
        let response = HTTPURLResponse(
            url: try #require(URL(string: "https://relay.example.com/api/register")),
            statusCode: 503,
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

    @Test
    func tokenRedactionScrubsBearerHeader() {
        #expect(
            SessionSharingTokenRedaction.redact("Authorization: Bearer abc-123_def")
                == "Authorization: Bearer [REDACTED]"
        )
    }

    @Test
    func tokenRedactionScrubsSensitiveQueryParams() {
        #expect(
            SessionSharingTokenRedaction.redact("ws://r/ws/client?id=foo&token=secret")
                == "ws://r/ws/client?id=foo&token=[REDACTED]"
        )
        #expect(
            SessionSharingTokenRedaction.redact("/api?client_token=AAAA&agent_token=BBBB&other=keep")
                == "/api?client_token=[REDACTED]&agent_token=[REDACTED]&other=keep"
        )
    }

    @Test
    func tokenRedactionLeavesNonSensitiveTextUnchanged() {
        let input = "ws://r/ws/client?id=foo"
        #expect(SessionSharingTokenRedaction.redact(input) == input)
    }

    @Test
    func tokenRedactionExtractsErrorLocalizedDescription() {
        struct LeakingError: LocalizedError {
            var errorDescription: String? { "fetch failed: ?token=secret&id=1" }
        }
        #expect(
            SessionSharingTokenRedaction.redact(error: LeakingError())
                == "fetch failed: ?token=[REDACTED]&id=1"
        )
    }

    @Test
    func errorPresentationMapsSharingErrorsToActionableHints() {
        #expect(
            SessionSharingErrorPresentation.actionableMessage(for: SessionSharingError.invalidRelayAddress)
                .contains("中转服务器地址无效")
        )
        #expect(
            SessionSharingErrorPresentation.actionableMessage(for: SessionSharingError.invalidResponse)
                .contains("中转服务器返回了无效响应")
        )
        #expect(
            SessionSharingErrorPresentation.actionableMessage(for: SessionSharingError.insecureRelayAddress)
                .contains("https:// 或 wss://")
        )
        let tokenRejected = SessionSharingErrorPresentation.actionableMessage(
            for: SessionSharingError.userTokenRejected
        )
        #expect(tokenRejected.contains("用户令牌被中转服务器拒绝"))
        #expect(tokenRejected.contains("GHOSTTY_RELAY_USER_TOKENS"))
    }

    @Test
    func errorPresentationMapsURLErrorsToActionableHints() {
        let scenarios: [(URLError.Code, String)] = [
            (.cannotFindHost, "找不到中转服务器主机"),
            (.cannotConnectToHost, "无法连接到中转服务器"),
            (.timedOut, "连接中转服务器超时"),
            (.notConnectedToInternet, "当前没有可用网络"),
            (.serverCertificateUntrusted, "TLS 证书校验失败"),
        ]
        for (code, expectedFragment) in scenarios {
            let message = SessionSharingErrorPresentation.actionableMessage(for: URLError(code))
            #expect(
                message.contains(expectedFragment),
                "URLError(\(code)) should mention '\(expectedFragment)', got: \(message)"
            )
        }
    }

    @Test
    func errorPresentationFallsBackToRedactedDescriptionForUnknownErrors() {
        struct UnknownError: LocalizedError {
            var errorDescription: String? {
                "boom while authenticating with Bearer s3cret-token"
            }
        }
        let message = SessionSharingErrorPresentation.actionableMessage(for: UnknownError())
        #expect(message.hasPrefix("启动共享失败："))
        #expect(message.contains("Bearer [REDACTED]"))
        #expect(!message.contains("s3cret-token"))
    }

    @Test
    func inboundFrameRecognisesClientConnected() {
        let action = SessionSharingInboundFrameAction.parse(
            text: #"{"type":"client_connected"}"#,
            sessionID: "abc"
        )
        #expect(action == .clientConnected)
    }

    @Test
    func screenSnapshotEncodesBase64WithClearAndHomePrefix() throws {
        let payload = SessionSharingScreenSnapshotPayload.encode(
            body: "hello\nworld",
            sessionID: "abc"
        )

        #expect(payload.type == "screen")
        #expect(payload.id == "abc")

        let bytes = try #require(Data(base64Encoded: payload.content))
        let expected = Data("\u{1b}[2J\u{1b}[Hhello\r\nworld".utf8)
        #expect(bytes == expected)

        let json = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(
            SessionSharingScreenSnapshotPayload.self, from: json
        )
        #expect(decoded == payload)
    }

    @Test
    func screenSnapshotAppendsCursorPositioningWhenProvided() throws {
        // Without a cursor argument, the snapshot must remain byte-for-byte
        // identical to the legacy output so existing recordings replay
        // unchanged through xterm.js.
        let baseline = SessionSharingScreenSnapshotPayload.encode(
            body: "hello",
            sessionID: "abc"
        )
        let baselineBytes = try #require(Data(base64Encoded: baseline.content))
        #expect(baselineBytes == Data("\u{1b}[2J\u{1b}[Hhello".utf8))

        // With a cursor, the encoded payload tails with
        // `\x1b[<row>;<col>H` (1-indexed) so xterm anchors its cursor
        // to the host's actual position rather than the end of the
        // snapshot text.
        let withCursor = SessionSharingScreenSnapshotPayload.encode(
            body: "hello",
            sessionID: "abc",
            cursorRow: 22,
            cursorCol: 4
        )
        let cursorBytes = try #require(Data(base64Encoded: withCursor.content))
        #expect(cursorBytes == Data("\u{1b}[2J\u{1b}[Hhello\u{1b}[23;5H".utf8))
    }

    @Test
    func screenSnapshotPadsTrailingBlankRowsExplicitly() throws {
        // trailingBlankRows = 3: 3 padding `\r\n` between body and
        // cursor anchor, so xterm's viewport bottom catches up with
        // host's active screen bottom (which had 3 blank rows the
        // formatter trimmed).
        let padded = SessionSharingScreenSnapshotPayload.encode(
            body: "row0\r\nrow1",
            sessionID: "abc",
            trailingBlankRows: 3,
            cursorRow: 3,
            cursorCol: 0
        )
        let bytes = try #require(Data(base64Encoded: padded.content))
        #expect(
            bytes == Data(
                "\u{1b}[2J\u{1b}[Hrow0\r\nrow1\r\n\r\n\r\n\u{1b}[4;1H".utf8
            )
        )

        // Default (no padding) preserves the legacy encoder output for
        // recordings that don't supply the trim count.
        let unpadded = SessionSharingScreenSnapshotPayload.encode(
            body: "row0\r\nrow1",
            sessionID: "abc"
        )
        let unpaddedBytes = try #require(Data(base64Encoded: unpadded.content))
        #expect(unpaddedBytes == Data("\u{1b}[2J\u{1b}[Hrow0\r\nrow1".utf8))
    }

    @Test
    func screenSnapshotIdempotentlyNormalisesCRLF() throws {
        // The styled .vt readback already emits \r\n separators, so the
        // encoder must not turn each \r\n into \r\r\n. Bytes coming
        // from the legacy plaintext path (\n only) still get expanded
        // to \r\n.
        let alreadyCRLF = SessionSharingScreenSnapshotPayload.encode(
            body: "row1\r\nrow2",
            sessionID: "abc"
        )
        let bareLF = SessionSharingScreenSnapshotPayload.encode(
            body: "row1\nrow2",
            sessionID: "abc"
        )
        #expect(alreadyCRLF.content == bareLF.content)
        let bytes = try #require(Data(base64Encoded: alreadyCRLF.content))
        #expect(bytes == Data("\u{1b}[2J\u{1b}[Hrow1\r\nrow2".utf8))
    }

    @Test
    func scrollbackSlicerNormalisesCRLF() throws {
        let history = "row0\r\nrow1\r\nrow2"
        let payload = SessionSharingScrollbackPayload.slice(
            history: history,
            sessionID: "abc",
            before: 1,
            requestedCount: 2
        )
        let bytes = try #require(Data(base64Encoded: payload.content))
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(text == "row0\r\nrow1")
        #expect(payload.count == 2)
        #expect(payload.total == 3)
    }

    @Test
    func inboundFrameRecognisesFetchScrollback() {
        let action = SessionSharingInboundFrameAction.parse(
            text: #"{"type":"fetch_scrollback","before":3,"count":50}"#,
            sessionID: "abc"
        )
        #expect(action == .fetchScrollback(before: 3, count: 50))
    }

    @Test
    func inboundFrameRejectsFetchScrollbackWithBadFields() {
        let cases: [(text: String, expected: SessionSharingInboundFrameAction)] = [
            (#"{"type":"fetch_scrollback","before":-1,"count":10}"#, .ignore),
            (#"{"type":"fetch_scrollback","before":0,"count":0}"#, .ignore),
            (#"{"type":"fetch_scrollback","before":0}"#, .ignore),
        ]
        for (text, expected) in cases {
            #expect(
                SessionSharingInboundFrameAction.parse(text: text, sessionID: "abc")
                    == expected
            )
        }
    }

    @Test
    func scrollbackSlicerReturnsNewestRowsForBeforeZero() throws {
        let history = (0..<5)
            .map { "row\($0)" }
            .joined(separator: "\n")
        let payload = SessionSharingScrollbackPayload.slice(
            history: history,
            sessionID: "abc",
            before: 0,
            requestedCount: 2
        )
        #expect(payload.before == 0)
        #expect(payload.count == 2)
        #expect(payload.total == 5)
        let bytes = try #require(Data(base64Encoded: payload.content))
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(text == "row3\r\nrow4")
    }

    @Test
    func scrollbackSlicerWalksOlderViaBefore() throws {
        let history = (0..<5)
            .map { "row\($0)" }
            .joined(separator: "\n")
        let first = SessionSharingScrollbackPayload.slice(
            history: history,
            sessionID: "abc",
            before: 0,
            requestedCount: 2
        )
        let second = SessionSharingScrollbackPayload.slice(
            history: history,
            sessionID: "abc",
            before: first.count,
            requestedCount: 2
        )
        let bytes = try #require(Data(base64Encoded: second.content))
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(text == "row1\r\nrow2")
        #expect(second.count == 2)
        #expect(second.total == 5)
    }

    @Test
    func scrollbackSlicerClampsAtOldestRow() throws {
        let history = "row0\nrow1\nrow2"
        let payload = SessionSharingScrollbackPayload.slice(
            history: history,
            sessionID: "abc",
            before: 2,
            requestedCount: 5
        )
        // Only row0 is older than the two newest, so we get a single
        // line back and `total` confirms the agent has nothing more.
        let bytes = try #require(Data(base64Encoded: payload.content))
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(text == "row0")
        #expect(payload.count == 1)
        #expect(payload.total == 3)
    }

    @Test
    func screenSnapshotTrimsHistoryAtLineBoundaryWhenOverBudget() throws {
        // Build a body that is well over the snapshot byte budget. Each
        // line is ~ 2 KiB so the agent has to drop the oldest ones to
        // fit a 32 KiB raw payload (less the \x1b[2J\x1b[H prefix).
        let lineWidth = 2048
        let lineCount = 32
        let lines = (0..<lineCount).map { index -> String in
            let prefix = String(format: "%04d ", index)
            let filler = String(
                repeating: "x",
                count: max(0, lineWidth - prefix.utf8.count - 1)
            )
            return prefix + filler
        }
        let body = lines.joined(separator: "\n")

        let payload = SessionSharingScreenSnapshotPayload.encode(
            body: body,
            sessionID: "abc"
        )
        let bytes = try #require(Data(base64Encoded: payload.content))

        let prefix = Data("\u{1b}[2J\u{1b}[H".utf8)
        #expect(bytes.starts(with: prefix))
        #expect(
            bytes.count
                <= SessionSharingScreenSnapshotPayload.snapshotByteBudget
        )

        let body_text = try #require(
            String(data: bytes.subdata(in: prefix.count..<bytes.count), encoding: .utf8)
        )
        // Whatever survived must end with the most recent line and start
        // at a clean line boundary (i.e. the trim respected \n).
        #expect(body_text.hasSuffix(lines.last!))
        let firstLineStart = body_text.split(separator: "\r\n", maxSplits: 1).first ?? ""
        #expect(firstLineStart.hasPrefix(String(format: "%04d ", lineCount - 1))
                || lines.contains { $0 == String(firstLineStart) })
    }

    @Test
    func appearancePayloadEncodesSnakeCaseFontSize() throws {
        let payload = SessionSharingAppearancePayload(
            type: "appearance",
            id: "abc",
            background: "#171412",
            foreground: "#f5f0e8",
            palette: Array(repeating: "#000000", count: 16),
            fontSize: 14
        )

        let data = try JSONEncoder().encode(payload)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(json["type"] as? String == "appearance")
        #expect(json["id"] as? String == "abc")
        #expect(json["background"] as? String == "#171412")
        #expect(json["foreground"] as? String == "#f5f0e8")
        #expect(json["font_size"] as? Double == 14)
        #expect((json["palette"] as? [String])?.count == 16)
        #expect(json["fontSize"] == nil)

        let decoded = try JSONDecoder().decode(
            SessionSharingAppearancePayload.self, from: data
        )
        #expect(decoded == payload)
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
