import XCTest
@testable import SideSign
@testable import ReSign

final class AuthenticationRequestTests: XCTestCase {
    private var session: URLSession!
    private var portal: DeveloperPortal!

    override func setUp() {
        AuthenticationResponseProtocol.reset(0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthenticationResponseProtocol.self]
        session = URLSession(configuration: configuration)
        portal = DeveloperPortal(session: session)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        portal = nil
        session = nil
    }

    func testTokenRequestKeepsMacProviderHeaders() async throws {
        let data = macData()
        let result = try await portal.sendAuthenticationRequest(parameters: ["o": "apptokens"], anisetteData: data)
        let requests = AuthenticationResponseProtocol.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-MMe-Client-Info"), data.clientInfo)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "User-Agent"), data.userAgent)
        XCTAssertNotNil(result["et"])
    }

    func testTokenRejectionsStopWithoutTryingAnotherIdentity() async throws {
        for code in [-80046, -22410] {
            AuthenticationResponseProtocol.reset(code)
            let data = macData()
            do {
                _ = try await portal.sendAuthenticationRequest(parameters: ["o": "apptokens"], anisetteData: data)
                XCTFail("Rejected token requests must fail")
            } catch let error as ServerError {
                guard case .underlyingError(let actualCode, let message) = error else { throw error }
                XCTAssertEqual(actualCode, code)
                XCTAssertTrue(message.contains("签名令牌申请"))
            }
            let requests = AuthenticationResponseProtocol.requests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-MMe-Client-Info"), data.clientInfo)
        }
    }

    func testAuthenticationFailuresReportRequestStage() async throws {
        for (operation, stage) in [("init", "账号握手"), ("complete", "密码验证"), ("apptokens", "签名令牌申请")] {
            AuthenticationResponseProtocol.reset(-22410)
            do {
                _ = try await portal.sendAuthenticationRequest(parameters: ["o": operation], anisetteData: macData())
                XCTFail("Synthetic error must be reported")
            } catch let error as ServerError {
                guard case .underlyingError(-22410, let message) = error else { throw error }
                XCTAssertTrue(message.contains(stage))
            }
            XCTAssertEqual(AuthenticationResponseProtocol.requests().count, 1)
        }
    }

    func testSessionRefreshRequiresSameProviderAndMachine() throws {
        let issued = macData()
        var fresh = issued
        fresh.oneTimePassword = "fresh-otp"
        fresh.clientTime = "2026-11-05T09:00:00Z"
        XCTAssertEqual(try SigningService.refreshedAnisette(fresh, issued: issued), fresh)
        for keyPath in [\AnisetteData.deviceID, \.localUserID, \.machineID, \.routingInfo, \.clientInfo, \.userAgent] {
            var mismatched = fresh
            mismatched[keyPath: keyPath] = "changed"
            XCTAssertThrowsError(try SigningService.refreshedAnisette(mismatched, issued: issued))
        }
    }

    func testMacClientInfoCompatibilityPreservesProviderDetails() {
        let original = macData().clientInfo
        let expected = "<MacBookPro16,2> <Mac OS X;26.7.1;25G241> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        XCTAssertEqual(AnisetteService.compatibleClientInfo(original), expected)
        for value in [expected, "<PC> <Windows;6.2;9200> <com.apple.AuthKit/1>"] {
            XCTAssertEqual(AnisetteService.compatibleClientInfo(value), value)
        }
    }

    func testChangedClientInfoUsesSeparateProvisioningIdentity() throws {
        let original = macData()
        var compatible = original
        compatible.clientInfo = AnisetteService.compatibleClientInfo(original.clientInfo)
        let server = URL(string: "https://anisette.example.com")!
        XCTAssertNotEqual(
            AnisetteService.identityKey(server: server, clientInfo: original.clientInfo, userAgent: original.userAgent),
            AnisetteService.identityKey(server: server, clientInfo: compatible.clientInfo, userAgent: compatible.userAgent))
        XCTAssertThrowsError(try SigningService.refreshedAnisette(compatible, issued: original))
        XCTAssertEqual(try SigningService.refreshedAnisette(compatible, issued: compatible), compatible)
    }

    func testInvalidResponsesReportHTTPStatusAndStageWithoutPayload() async throws {
        for (operation, stage) in [("init", "账号握手"), ("complete", "密码验证"), ("apptokens", "签名令牌申请")] {
            for (status, body) in [(503, "<html>private-response</html>"), (200, "invalid-private-response"), (502, "")] {
                AuthenticationResponseProtocol.reset(0, httpStatus: status, body: Data(body.utf8))
                do {
                    _ = try await portal.sendAuthenticationRequest(parameters: ["o": operation], anisetteData: macData())
                    XCTFail("Invalid responses must fail")
                } catch let error as ServerError {
                    guard case .badServerResponse(let reason, let payload) = error else { throw error }
                    XCTAssertTrue(reason.contains(stage))
                    XCTAssertTrue(reason.contains("HTTP \(status)"))
                    if !body.isEmpty { XCTAssertTrue(reason.contains("text/html")) }
                    XCTAssertTrue(payload.isEmpty)
                    XCTAssertFalse(error.localizedDescription.contains("private-response"))
                }
                XCTAssertEqual(AuthenticationResponseProtocol.requests().count, 1)
            }
        }
    }

    func testHTTPFailureCannotBecomeSuccessfulAuthentication() async throws {
        AuthenticationResponseProtocol.reset(0, httpStatus: 503)
        do {
            _ = try await portal.sendAuthenticationRequest(parameters: ["o": "init"], anisetteData: macData())
            XCTFail("HTTP failures must not succeed even with ec=0")
        } catch let error as ServerError {
            guard case .badServerResponse(let reason, _) = error else { throw error }
            XCTAssertTrue(reason.contains("HTTP 503"))
        }
    }

    func testHTTPFailurePreservesStructuredAppleError() async throws {
        AuthenticationResponseProtocol.reset(-22410, httpStatus: 401)
        do {
            _ = try await portal.sendAuthenticationRequest(parameters: ["o": "init"], anisetteData: macData())
            XCTFail("Apple rejection must fail")
        } catch let error as ServerError {
            guard case .underlyingError(-22410, let message) = error else { throw error }
            XCTAssertTrue(message.contains("账号握手"))
        }
    }

    private func macData() -> AnisetteData {
        AnisetteData(machineID: "test-machine", oneTimePassword: "test-otp", localUserID: "test-local-user",
                     routingInfo: "17106176", deviceID: "test-device", serialNumber: "0",
                     clientInfo: "<MacBookPro16,2> <macOS;26.7.1;25G241> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
                     userAgent: "akd/1.0 CFNetwork/3860.100.1 Darwin/25.0.0",
                     clientTime: "2026-11-05T08:00:00Z", locale: "en_US", timeZone: "UTC")
    }
}

private final class AuthenticationResponseProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var code = 0
    nonisolated(unsafe) private static var httpStatus = 200
    nonisolated(unsafe) private static var body: Data?
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func reset(_ value: Int, httpStatus: Int = 200, body: Data? = nil) {
        lock.withLock {
            code = value
            Self.httpStatus = httpStatus
            Self.body = body
            recorded = []
        }
    }
    static func requests() -> [URLRequest] { lock.withLock { recorded } }

    // All requests are intercepted by the test protocol; these tests do not use networking.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (code, status, body) = Self.lock.withLock {
            Self.recorded.append(request)
            return (Self.code, Self.httpStatus, Self.body)
        }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: [
                "Response": ["Status": ["ec": code, "em": "Synthetic response"], "et": Data([1, 2, 3])]
            ], format: .xml, options: 0)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": body == nil ? "text/x-xml-plist" : "text/html"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body ?? data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}
}
