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
                    for try await wsMessage in inbound.messages(maxSize: 1_000_000) {
                        // Ignore non text frames
                        guard case .text(let message) = wsMessage else { continue }

                        // construct message text
                        let messageText = "[\(username)] - \(message)"

                        // Publish to channel
                        try await self.valkey.publish(channel: messagesChannel, message: messageText)
                    }
                }

                group.addTask {
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
