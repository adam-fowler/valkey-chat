import Foundation
import Hummingbird
import HummingbirdWebSocket
import Valkey

struct StreamController {
    let valkey: ValkeyClient
    let channel = "chat/Stream/ServerSide.swift"

    var routes: RouteCollection<BasicWebSocketRequestContext> {
        let key = ValkeyKey(channel)
        let routes = RouteCollection(context: BasicWebSocketRequestContext.self)

        routes.ws("v2/chat") { request, _ in
            // only allow upgrade if username query parameter exists
            guard request.uri.queryParameters["username"] != nil else {
                return .dontUpgrade
            }
            return .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            // only allow upgrade if username query parameter exists
            guard let username = context.request.uri.queryParameters["username"] else {
                try await outbound.close(.unexpectedServerError, reason: "Username required")
                return
            }

            _ = await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    /// Read messages from WebSocket and publish them to the stream
                    try await self.valkey.xadd(
                        key,
                        idSelector: .autoId,
                        data: [
                            .init(field: "name", value: "\(username)"),
                            .init(field: "action", value: "joined"),
                        ]
                    )
                    for try await frame in inbound.messages(maxSize: 1_000_000) {
                        guard case .text(let message) = frame else { continue }
                        try await self.valkey.xadd(
                            key,
                            idSelector: .autoId,
                            data: [
                                .init(field: "name", value: "\(username)"),
                                .init(field: "action", value: "message"),
                                .init(field: "message", value: "\(message)"),
                            ]
                        )
                    }
                    try await self.valkey.xadd(
                        key,
                        idSelector: .autoId,
                        data: [
                            .init(field: "name", value: "\(username)"),
                            .init(field: "action", value: "left"),
                        ]
                    )
                }

                group.addTask {
                    try await valkey.withConnection { connection in
                        var id = "\(Int((Date.now.timeIntervalSince1970 - 600) * 1000))-0"
                        while true {
                            // Read from stream. Blocking for 10 seconds if nothing is currently available
                            guard let response = try await self.valkey.xread(milliseconds: 10000, streams: .init(keys: [key], ids: [id])) else {
                                continue
                            }
                            for stream in response.streams {
                                for message in stream.messages {
                                    if let name = message[field: "name"].map({ String(buffer: $0) }) {
                                        let action = message[field: "action"].map { String(buffer: $0) }
                                        switch action {
                                        case "joined":
                                            if name != username {
                                                try await outbound.write(.text("\(name) joined"))
                                            }
                                        case "left":
                                            try await outbound.write(.text("\(name) left"))
                                        case "message":
                                            if let message = message[field: "message"].map({ String(buffer: $0) }) {
                                                try await outbound.write(.text("[\(name)] - \(message)"))
                                            }
                                        default:
                                            break
                                        }
                                    }
                                    id = message.id
                                }
                            }
                        }
                    }
                }
            }
        }
        return routes
    }
}
