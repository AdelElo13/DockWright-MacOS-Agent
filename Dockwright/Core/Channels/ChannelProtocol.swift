import Foundation

/// Protocol for message delivery channels (notifications, chat, etc.)
nonisolated protocol DeliveryChannel: Sendable {
    var name: String { get }
    func send(title: String, body: String) async throws
}
