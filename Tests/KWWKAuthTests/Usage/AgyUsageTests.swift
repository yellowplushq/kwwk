import Foundation
import Testing
@testable import KWWKAuth

@Suite("Antigravity CLI (agy) subscription usage")
struct AgyUsageTests {
    private let fixedVersion = AgyHubVersion(fixed: "2.35.1")

    private func reader() -> AgyUsageReader {
        AgyUsageReader(hubVersion: fixedVersion)
    }

    // MARK: - Summary normalization

    @Test("Multi-pool retrieveUserQuotaSummary emits tightest account summary windows followed by per-pool rows")
    func multiPoolSummary() throws {
        let json = #"""
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "description": "Models within this group: Gemini 4 Neon, Gemini 3.8 Flash",
              "buckets": [
                {
                  "bucketId": "gemini-weekly",
                  "displayName": "Weekly Limit Remaining",
                  "window": "weekly",
                  "resetTime": "2026-12-02T02:03:31Z",
                  "remainingFraction": 0.2
                },
                {
                  "bucketId": "gemini-5h",
                  "displayName": "Five Hour Limit Remaining",
                  "window": "5h",
                  "resetTime": "2026-11-26T05:00:00.500000Z",
                  "remainingFraction": 0.6
                }
              ]
            },
            {
              "displayName": "Claude and GPT models",
              "description": "Models within this group: Claude Sonnet 5.5, Claude Opus 5.5, GPT-OSS 120B",
              "buckets": [
                {
                  "bucketId": "3p-weekly",
                  "displayName": "Weekly Limit Remaining",
                  "window": "weekly",
                  "resetTime": "2026-12-02T15:59:45Z",
                  "remainingFraction": 0.75
                },
                {
                  "bucketId": "3p-5h",
                  "displayName": "Five Hour Limit Remaining",
                  "window": "5h",
                  "resetTime": "2026-11-26T04:00:00Z",
                  "remainingFraction": 0.15
                }
              ]
            }
          ]
        }
        """#

        let windows = try AgyUsageReader.windows(fromSummaryJSON: Data(json.utf8))
        #expect(windows.count == 6)

        // Account-level summary windows first (tightest across pools).
        #expect(windows[0].limitID == nil)
        #expect(windows[0].limitName == nil)
        #expect(windows[0].window == .fiveHour)
        #expect(windows[0].windowSeconds == 18_000)
        #expect(abs(windows[0].usedPercent - 85) < 0.001)
        #expect(windows[0].resetsAt == 1_795_665_600_000)

        #expect(windows[1].limitID == nil)
        #expect(windows[1].limitName == nil)
        #expect(windows[1].window == .sevenDay)
        #expect(windows[1].windowSeconds == 604_800)
        #expect(abs(windows[1].usedPercent - 80) < 0.001)
        #expect(windows[1].resetsAt == 1_796_177_011_000)

        // Per-pool rows in server group order, 5h before 7d within each pool.
        #expect(windows[2].limitID == "agy:gemini")
        #expect(windows[2].limitName == "Gemini")
        #expect(windows[2].window == .fiveHour)
        #expect(abs(windows[2].usedPercent - 40) < 0.001)
        #expect(windows[2].resetsAt == 1_795_669_200_500)

        #expect(windows[3].limitID == "agy:gemini")
        #expect(windows[3].limitName == "Gemini")
        #expect(windows[3].window == .sevenDay)
        #expect(abs(windows[3].usedPercent - 80) < 0.001)

        #expect(windows[4].limitID == "agy:claude-gpt")
        #expect(windows[4].limitName == "Claude & GPT")
        #expect(windows[4].window == .fiveHour)
        #expect(abs(windows[4].usedPercent - 85) < 0.001)

        #expect(windows[5].limitID == "agy:claude-gpt")
        #expect(windows[5].limitName == "Claude & GPT")
        #expect(windows[5].window == .sevenDay)
        #expect(abs(windows[5].usedPercent - 25) < 0.001)

        // Every window must have a unique (limitID, window) identity for UI rendering.
        let ids = windows.map { "\($0.limitID ?? "")|\($0.window.rawValue)" }
        #expect(Set(ids).count == ids.count)
    }

    @Test("Exhausted bucket with omitted or zero remainingFraction normalizes to 100% used")
    func exhaustedBuckets() throws {
        let json = #"""
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {
                  "bucketId": "gemini-weekly",
                  "window": "weekly",
                  "resetTime": "2026-12-02T02:03:31Z"
                }
              ]
            },
            {
              "displayName": "Claude and GPT models",
              "buckets": [
                {
                  "bucketId": "3p-weekly",
                  "window": "weekly",
                  "remainingFraction": 1
                },
                {
                  "bucketId": "3p-5h",
                  "window": "5h",
                  "remainingFraction": 0
                }
              ]
            }
          ]
        }
        """#

        let windows = try AgyUsageReader.windows(fromSummaryJSON: Data(json.utf8))
        let summary5h = try #require(windows.first { $0.limitID == nil && $0.window == .fiveHour })
        let summary7d = try #require(windows.first { $0.limitID == nil && $0.window == .sevenDay })
        #expect(summary5h.usedPercent == 100)
        #expect(summary7d.usedPercent == 100)
        #expect(summary7d.resetsAt == 1_796_177_011_000)
    }

    @Test("Single-pool summary avoids duplicating identical rows and skips disabled buckets")
    func singlePoolAndDisabled() throws {
        let json = #"""
        {
          "groups": [
            {
              "displayName": "Claude and GPT models",
              "buckets": [
                {"bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.9},
                {"bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.5, "resetTime": "2026-12-02T15:59:45Z"},
                {"bucketId": "disabled-bucket", "window": "5h", "remainingFraction": 0, "disabled": true}
              ]
            }
          ]
        }
        """#

        let windows = try AgyUsageReader.windows(fromSummaryJSON: Data(json.utf8))
        #expect(windows.count == 2)
        #expect(windows.allSatisfy { $0.limitID == nil })
        #expect(windows[0].window == .fiveHour)
        #expect(abs(windows[0].usedPercent - 10) < 0.001)
        #expect(windows[1].window == .sevenDay)
        #expect(abs(windows[1].usedPercent - 50) < 0.001)
    }

    @Test("Custom window kinds and out-of-range remainingFraction values are handled safely")
    func customAndClampedBuckets() throws {
        let json = #"""
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {"bucketId": "daily-burst", "displayName": "Daily Burst", "window": "daily", "remainingFraction": 1.5},
                {"bucketId": "monthly-cap", "displayName": "Monthly Cap", "window": "monthly", "remainingFraction": -0.2}
              ]
            }
          ]
        }
        """#

        let windows = try AgyUsageReader.windows(fromSummaryJSON: Data(json.utf8))
        // Summary primary window + 2 distinct custom windows.
        #expect(windows.count == 3)
        #expect(windows[0].limitID == nil)
        #expect(windows[0].window == .primary)
        #expect(windows[0].usedPercent == 100)
        #expect(windows[1].limitID == "agy:gemini:daily-burst")
        #expect(windows[1].limitName == "Gemini · Daily Burst")
        #expect(windows[1].usedPercent == 0)
        #expect(windows[2].limitID == "agy:gemini:monthly-cap")
        #expect(windows[2].limitName == "Gemini · Monthly Cap")
        #expect(windows[2].usedPercent == 100)
    }

    // MARK: - Model fallback normalization

    @Test("fetchAvailableModels fallback aggregates raw models into family pools and skips hidden/disabled/tab models")
    func modelFallbackAggregation() throws {
        let json = #"""
        {
          "models": {
            "gemini-4-hydrogen-high": {"displayName": "Gemini 4 Hydrogen (High)", "quotaInfo": {"resetTime": "2026-12-02T02:03:31Z"}},
            "gemini-4-hydrogen-low": {"displayName": "Gemini 4 Hydrogen (Low)", "quotaInfo": {"remainingFraction": 0.4, "resetTime": "2026-12-02T02:03:31Z"}},
            "gemini-4-neon-disabled": {"displayName": "Gemini 4 Neon", "disabled": true, "quotaInfo": null},
            "claude-opus-4-6-thinking": {"displayName": "Claude Opus 4.6", "quotaInfo": {"remainingFraction": 0.8, "resetTime": "2026-12-02T16:00:00Z"}},
            "gpt-oss-120b-medium": {"displayName": "GPT-OSS 120B", "quotaInfo": {"remainingFraction": 1, "resetTime": "2026-12-02T16:00:00Z"}},
            "tab_flash_lite_preview": {"quotaInfo": {"remainingFraction": 0}},
            "chat_internal_helper": {"quotaInfo": {"remainingFraction": 0}}
          }
        }
        """#

        let windows = try AgyUsageReader.windows(fromModelsJSON: Data(json.utf8))
        #expect(windows.count == 3)
        #expect(windows[0].limitID == nil)
        #expect(windows[0].window == .primary)
        #expect(windows[0].usedPercent == 100)
        #expect(windows[0].resetsAt == 1_796_177_011_000)

        #expect(windows[1].limitID == "agy:gemini")
        #expect(windows[1].limitName == "Gemini")
        #expect(windows[1].usedPercent == 100)

        #expect(windows[2].limitID == "agy:claude-gpt")
        #expect(windows[2].limitName == "Claude & GPT")
        #expect(abs(windows[2].usedPercent - 20) < 0.001)
    }

    // MARK: - Wire protocol & project discovery

    @Test("Resolves projectId via loadCodeAssist when absent from extras, then reads retrieveUserQuotaSummary")
    func discoversProjectViaLoadCodeAssist() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"cloudaicompanionProject":"proj-123","currentTier":{"id":"free-tier"}}"#),
            .response(status: 200, body: #"""
            {"groups":[
              {"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0,"resetTime":"2026-12-02T02:03:31Z"}]},
              {"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-5h","window":"5h","remainingFraction":1}]}
            ]}
            """#),
        ])
        let creds = OAuthCredentials(access: "ya29.test", refresh: "never-sent", expires: .max, extras: ["email": "u@example.com"])
        let windows = try await reader().usage(creds, using: client)

        #expect(client.requestCount == 2)
        #expect(client.requests[0].url.absoluteString == "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
        #expect(client.header("Authorization", request: 0) == "Bearer ya29.test")
        #expect(client.header("User-Agent", request: 0)?.hasPrefix("antigravity/hub/2.35.1 ") == true)

        #expect(client.requests[1].url.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")
        let req1Body = try #require(client.requests[1].body)
        let req1JSON = try #require(JSONSerialization.jsonObject(with: req1Body) as? [String: Any])
        #expect(req1JSON["project"] as? String == "proj-123")

        #expect(windows.count == 4)
        #expect(windows[0].window == .fiveHour && windows[0].limitID == nil && windows[0].usedPercent == 0)
        #expect(windows[1].window == .sevenDay && windows[1].limitID == nil && windows[1].usedPercent == 100)
    }

    @Test("Skips loadCodeAssist when extras already carries projectId")
    func usesCachedProjectId() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.25}]}]}"#),
        ])
        let creds = OAuthCredentials(
            access: "ya29.cached",
            refresh: "",
            expires: .max,
            extras: ["projectId": "cached-proj"]
        )
        let windows = try await reader().usage(creds, using: client)

        #expect(client.requestCount == 1)
        #expect(client.requests[0].url.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")
        #expect(windows.count == 1)
        #expect(windows[0].window == .fiveHour)
        #expect(abs(windows[0].usedPercent - 75) < 0.001)
    }

    @Test("Supports object-shaped cloudaicompanionProject and fails cleanly when absent")
    func loadCodeAssistProjectShapes() async throws {
        let objectClient = QueuedHTTPClient([
            .response(status: 200, body: #"{"cloudaicompanionProject":{"id":"proj-obj"}}"#),
            .response(status: 200, body: #"{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0.5}]}]}"#),
        ])
        let creds = OAuthCredentials(access: "ya29.obj", refresh: "", expires: .max)
        let windows = try await reader().usage(creds, using: objectClient)
        #expect(windows.count == 1)
        let body = try #require(objectClient.requests[1].body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["project"] as? String == "proj-obj")

        let missingClient = QueuedHTTPClient([
            .response(status: 200, body: #"{"currentTier":{"id":"free-tier"}}"#),
        ])
        await #expect(throws: OAuthUsageError.unavailable(
            providerId: "agy",
            status: nil,
            detail: "Antigravity account has no Code Assist project"
        )) {
            _ = try await reader().usage(creds, using: missingClient)
        }
    }

    @Test("Falls back to fetchAvailableModels when summary is empty and retries without refused tier on 400")
    func fallbackToFetchAvailableModelsWithTierRetry() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"groups":[]}"#),
            .response(status: 400, body: #"{"error":{"code":400,"message":"Invalid argument"}}"#),
            .response(status: 200, body: #"{"models":{"gemini-4-neon-high":{"displayName":"Gemini 4 Neon","quotaInfo":{"remainingFraction":0.3}}}}"#),
        ])
        let creds = OAuthCredentials(
            access: "ya29.fb",
            refresh: "",
            expires: .max,
            extras: ["projectId": "p1", "paidTier": "g1-pro-tier"]
        )
        let windows = try await reader().usage(creds, using: client)

        #expect(client.requestCount == 3)
        #expect(client.requests[1].url.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")
        let req1Data = try #require(client.requests[1].body)
        let body1 = try #require(JSONSerialization.jsonObject(with: req1Data) as? [String: Any])
        #expect((body1["entitlement"] as? [String: Any])?["userTier"] as? String == "g1-pro-tier")

        let req2Data = try #require(client.requests[2].body)
        let body2 = try #require(JSONSerialization.jsonObject(with: req2Data) as? [String: Any])
        #expect(body2["entitlement"] == nil)

        #expect(windows.count == 1)
        #expect(abs(windows[0].usedPercent - 70) < 0.001)
    }

    // MARK: - Error mapping

    @Test("Maps 401, 403, 429 (with Retry-After), 5xx, undecodable body, and transport errors cleanly")
    func errorMapping() async {
        let creds = OAuthCredentials(access: "ya29.err", refresh: "", expires: .max, extras: ["projectId": "p1"])

        let rateLimited = QueuedHTTPClient([.response(status: 429, body: "", headers: ["Retry-After": "45"])])
        await #expect(throws: OAuthUsageError.rateLimited(retryAfterSeconds: 45)) {
            _ = try await reader().usage(creds, using: rateLimited)
        }
        #expect(rateLimited.requestCount == 1)

        let rateLimitedDefault = QueuedHTTPClient([.response(status: 429, body: "")])
        await #expect(throws: OAuthUsageError.rateLimited(retryAfterSeconds: 120)) {
            _ = try await reader().usage(creds, using: rateLimitedDefault)
        }

        let unauth = QueuedHTTPClient([.response(status: 401, body: #"{"error":"unauthenticated"}"#)])
        await #expect(throws: OAuthUsageError.unavailable(
            providerId: "agy",
            status: 401,
            detail: #"{"error":"unauthenticated"}"#
        )) {
            _ = try await reader().usage(creds, using: unauth)
        }
        #expect(unauth.requestCount == 1)

        let forbidden = QueuedHTTPClient([.response(status: 403, body: #"{"error":"denied"}"#)])
        await #expect(throws: OAuthUsageError.unavailable(
            providerId: "agy",
            status: 403,
            detail: #"{"error":"denied"}"#
        )) {
            _ = try await reader().usage(creds, using: forbidden)
        }
        #expect(forbidden.requestCount == 1)

        let serverError = QueuedHTTPClient([.response(status: 503, body: "unavailable")])
        await #expect(throws: OAuthUsageError.unavailable(
            providerId: "agy",
            status: 503,
            detail: "unavailable"
        )) {
            _ = try await reader().usage(creds, using: serverError)
        }

        let garbled = QueuedHTTPClient([.response(status: 200, body: "<html>")])
        await #expect(throws: OAuthUsageError.unavailable(
            providerId: "agy",
            status: 200,
            detail: "undecodable body"
        )) {
            _ = try await reader().usage(creds, using: garbled)
        }

        let transport = QueuedHTTPClient([.failure(URLError(.timedOut))])
        do {
            _ = try await reader().usage(creds, using: transport)
            Issue.record("expected unavailable error")
        } catch let error as OAuthUsageError {
            if case .unavailable(let providerId, let status, _) = error {
                #expect(providerId == "agy")
                #expect(status == nil)
            } else {
                Issue.record("unexpected error case: \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - Hub version & registration

    @Test("AgyHubVersion parses updater manifest, caches result, and falls back on error")
    func hubVersionManifest() async {
        #expect(AgyHubVersion.parse(manifest: "version: 2.35.1\nfiles: []\n") == "2.35.1")
        #expect(AgyHubVersion.parse(manifest: "version: '2.40.0'\n") == "2.40.0")
        #expect(AgyHubVersion.parse(manifest: "version: invalid-beta\n") == nil)

        let client = QueuedHTTPClient([
            .response(status: 200, body: "version: 2.99.0\n"),
        ])
        let resolver = AgyHubVersion()
        #expect(await resolver.current(client: client) == "2.99.0")
        // Second call uses the 6-hour cache and makes no additional request.
        #expect(await resolver.current(client: client) == "2.99.0")
        #expect(client.requestCount == 1)

        let offline = AgyHubVersion()
        #expect(await offline.current(client: QueuedHTTPClient([.failure(URLError(.notConnectedToInternet))])) == AgyHubVersion.fallback)

        // Hung manifest fetch aborts via CancellationHandle when fetchTimeoutSeconds elapses.
        let hungManifest = HandleOnlyCancellingHTTPClient(initialResponses: [])
        let timedOutVersion = await AgyHubVersion(fetchTimeoutSeconds: 0.05).current(client: hungManifest)
        #expect(timedOutVersion == AgyHubVersion.fallback)
        #expect(hungManifest.hungTimeoutSeconds == 0.05)
        #expect(hungManifest.hungHadCancellationHandle == true)
        #expect(hungManifest.cancelReasons == ["timeout"])
    }

    @Test("AgyUsageReader passes bounded timeouts and propagates parent Task cancellation to CancellationHandle")
    func boundedTimeoutsAndTaskCancellation() async throws {
        // 1. Cold path passes 10s for loadCodeAssist and 15s for retrieveUserQuotaSummary.
        let recorder = HandleOnlyCancellingHTTPClient(initialResponses: [
            .response(status: 200, body: #"{"cloudaicompanionProject":"p-timeout"}"#),
            .response(status: 200, body: #"{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"5h","remainingFraction":0.5}]}]}"#),
        ])
        let creds = OAuthCredentials(access: "ya29.t", refresh: "", expires: .max)
        let windows = try await reader().usage(creds, using: recorder)
        #expect(windows.count == 1)
        #expect(recorder.recordedTimeouts == [10, 15])

        // 2. Parent Task cancellation cancels a hung quota call via CancellationHandle immediately.
        let hung = HandleOnlyCancellingHTTPClient(initialResponses: [])
        let warmCreds = OAuthCredentials(access: "ya29.t", refresh: "", expires: .max, extras: ["projectId": "p-hung"])
        let task = Task {
            try await reader().usage(warmCreds, using: hung)
        }
        await hung.waitUntilHung()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(hung.hungTimeoutSeconds == 15)
        #expect(hung.hungHadCancellationHandle == true)
        #expect(hung.cancelReasons == ["cancelled"])
    }

    @Test("AgyUsageReader is registered in OAuthUsage.readers under agy")
    func registered() {
        #expect(OAuthUsage.readers["agy"] is AgyUsageReader)
    }
}
