import Foundation

/// Swift mirror of `chrome-extension/src/protocol.ts`.
///
/// Decoding is intentionally lenient: an unrecognised message type is ignored rather than
/// failing the connection, so an older app and a newer extension keep working together.
enum BridgeProtocol {

    // MARK: - Extension → app

    struct TabPayload: Decodable {
        let tabId: Int
        let windowId: Int
        let title: String
        let url: String
        let active: Bool
        let pinned: Bool
        let index: Int
        /// Milliseconds since epoch; Chrome 121+ only.
        let lastAccessed: Double?
    }

    enum Inbound {
        case hello(extensionVersion: String)
        case inventory(tabs: [TabPayload], focusedWindowId: Int?)
        case tabUpdated(TabPayload)
        case tabActivated(tabId: Int, windowId: Int)
        case tabRemoved(tabId: Int)
        case windowRemoved(windowId: Int)
        case windowFocusChanged(windowId: Int?)
        case activateResult(requestId: String, ok: Bool, error: String?)
        case unknown(String)

        static func decode(_ data: Data) throws -> Inbound {
            let decoder = JSONDecoder()
            let envelope = try decoder.decode(Envelope.self, from: data)

            switch envelope.type {
            case "hello":
                let message = try decoder.decode(HelloMessage.self, from: data)
                return .hello(extensionVersion: message.extensionVersion)
            case "inventory":
                let message = try decoder.decode(InventoryMessage.self, from: data)
                return .inventory(tabs: message.tabs, focusedWindowId: message.focusedWindowId)
            case "tab_updated":
                let message = try decoder.decode(TabUpdatedMessage.self, from: data)
                return .tabUpdated(message.tab)
            case "tab_activated":
                let message = try decoder.decode(TabActivatedMessage.self, from: data)
                return .tabActivated(tabId: message.tabId, windowId: message.windowId)
            case "tab_removed":
                let message = try decoder.decode(TabRemovedMessage.self, from: data)
                return .tabRemoved(tabId: message.tabId)
            case "window_removed":
                let message = try decoder.decode(WindowRemovedMessage.self, from: data)
                return .windowRemoved(windowId: message.windowId)
            case "window_focus_changed":
                let message = try decoder.decode(WindowFocusMessage.self, from: data)
                return .windowFocusChanged(windowId: message.windowId)
            case "activate_result":
                let message = try decoder.decode(ActivateResultMessage.self, from: data)
                return .activateResult(
                    requestId: message.requestId, ok: message.ok, error: message.error
                )
            default:
                return .unknown(envelope.type)
            }
        }
    }

    private struct Envelope: Decodable { let type: String }
    private struct HelloMessage: Decodable { let extensionVersion: String }
    private struct InventoryMessage: Decodable {
        let tabs: [TabPayload]
        let focusedWindowId: Int?
    }
    private struct TabUpdatedMessage: Decodable { let tab: TabPayload }
    private struct TabActivatedMessage: Decodable { let tabId: Int; let windowId: Int }
    private struct TabRemovedMessage: Decodable { let tabId: Int }
    private struct WindowRemovedMessage: Decodable { let windowId: Int }
    private struct WindowFocusMessage: Decodable { let windowId: Int? }
    private struct ActivateResultMessage: Decodable {
        let requestId: String
        let ok: Bool
        let error: String?
    }

    // MARK: - App → extension

    enum Outbound: Encodable {
        case activateTab(requestId: String, tabId: Int, windowId: Int)
        case requestInventory

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .activateTab(let requestId, let tabId, let windowId):
                try container.encode("activate_tab", forKey: .type)
                try container.encode(requestId, forKey: .requestId)
                try container.encode(tabId, forKey: .tabId)
                try container.encode(windowId, forKey: .windowId)
            case .requestInventory:
                try container.encode("request_inventory", forKey: .type)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type, requestId, tabId, windowId
        }
    }
}
