import Foundation
import Hummingbird
import HummingbirdWebSocket
import Valkey

struct ChatController {
    let valkey: ValkeyClient
    let channelPrefix = "chat/Channel/"
    let listPrefix = "chat/List/"

    var routes: RouteCollection<BasicWebSocketRequestContext> {
        let routes = RouteCollection(context: BasicWebSocketRequestContext.self)

        routes.ws("api/chat") { request, _ in
            // only allow upgrade if username and channel query parameters exist
            guard request.uri.queryParameters["username"] != nil,
                request.uri.queryParameters["channel"] != nil
            else {
                return .dontUpgrade
            }
            return .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            let username = try context.request.uri.queryParameters.require("username")
            let channelName = try context.request.uri.queryParameters.require("channel")
            /// Setup key names
            let messagesChannel = "\(self.channelPrefix)\(channelName)"
            let messagesKey = ValkeyKey("\(self.listPrefix)\(channelName)")

            await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    /// Read messages from WebSocket
                    for try await frame in inbound.messages(maxSize: 1_000_000) {
                        // Ignore non text frames
                        guard case .text(let message) = frame else { continue }

                        // construct message text
                        let messageText = "[\(username)] - \(message)"

                        // Add to message stream and publish to channel
                        let responses = await self.valkey.execute(
                            XADD(
                                messagesKey,
                                idSelector: .autoId,
                                data: [
                                    .init(field: "username", value: "\(username)"),
                                    .init(field: "message", value: "\(message)"),
                                ]
                            ),
                            PUBLISH(channel: messagesChannel, message: messageText)
                        )
                        _ = try responses.1.get()
                    }
                }

                group.addTask {
                    // Read messages already posted. (read messages from the last 10 minutes)
                    let id = "\(Int((Date.now.timeIntervalSince1970 - 600) * 1000))"
                    let messages = try await self.valkey.xrange(
                        messagesKey,
                        start: id,
                        end: "+"
                    )
                    // write those messages to the websocket
                    for message in messages {
                        guard let username = message[field: "username"].map({ String(buffer: $0) }),
                            let message = message[field: "message"].map({ String(buffer: $0) })
                        else {
                            continue
                        }
                        try await outbound.write(.text("[\(username)] - \(message)"))
                    }

                    /// Subscribe to channel and write any messages we receive to websocket
                    try await valkey.subscribe(to: [messagesChannel]) { subscription in
                        for try await event in subscription {
                            let message = String(buffer: event.message)
                            try await outbound.write(.text(message))
                        }
                    }
                }
            }
        }
        return routes
    }
}
