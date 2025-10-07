import Hummingbird
import HummingbirdTesting
import HummingbirdWSTesting
import Logging
import Testing

@testable import Chat

struct AppTests {
    struct TestArguments: AppArguments {
        let hostname = "127.0.0.1"
        let port = 0
        let logLevel: Logger.Level? = .trace
    }

    @Test
    func testApp() async throws {
        let args = TestArguments()
        let app = try await buildApplication(args)
        try await app.test(.live) { client in
            _ = try await client.ws("/api/chat?username=Adam&channel=valkey") { inbound, outbound, context in
                try await outbound.write(.text("Hello"))
                var iterator = inbound.makeAsyncIterator()
                let frame = try await iterator.next()
                #expect(frame?.opcode == .text)
                #expect(frame?.data == ByteBuffer(string: "[Adam] - Hello"))
            }
        }
    }
}
