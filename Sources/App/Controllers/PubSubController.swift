import Hummingbird
import HummingbirdWebSocket
import Valkey

struct PubSubController {
    let valkey: ValkeyClient
    let channel = "chat/PubSub/ServerSide.swift"

    var routes: RouteCollection<BasicWebSocketRequestContext> {
        let routes = RouteCollection(context: BasicWebSocketRequestContext.self)

        routes.ws("v1/chat") { request, _ in
            // only allow upgrade if username query parameter exists
            guard request.uri.queryParameters["username"] != nil else {
                return .dontUpgrade
            }
            return .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            // only allow upgrade if username query parameter exists
            guard let name = context.request.uri.queryParameters["username"] else {
                try await outbound.close(.unexpectedServerError, reason: "Username required")
                return
            }

            _ = try await withThrowingTaskGroup(of: Void.self) { group in
                _ = try await self.valkey.publish(channel: self.channel, message: "\(name) joined.")
                group.addTask {
                    /// Read messages from WebSocket and publish them to the channel
                    for try await frame in inbound.messages(maxSize: 1_000_000) {
                        guard case .text(let message) = frame else { continue }
                        _ = try await self.valkey.publish(channel: self.channel, message: "[\(name)] - \(message)")
                    }
                    _ = try await self.valkey.publish(channel: self.channel, message: "\(name) left.")
                }

                group.addTask {
                    try await outbound.write(.text("Say Hello!"))
                    try await valkey.withConnection { connection in
                        /// Subscribe to channel and write any messages we receive back to user
                        try await connection.subscribe(to: [self.channel]) { subscription in
                            for try await item in subscription {
                                try await outbound.write(.text(item.message))
                            }
                        }
                    }
                }
            }
        }
        return routes
    }
}
