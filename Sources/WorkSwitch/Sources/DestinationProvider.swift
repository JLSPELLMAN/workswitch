import Foundation

/// A source of destinations. Milestone 1 ships `NativeWindowProvider`; Milestone 2 adds a
/// Chrome tab provider fed by the native messaging bridge. The overlay, ranker, and model
/// stay unchanged when a provider is added.
protocol DestinationProvider {
    var typeName: String { get }
    func enumerate() -> [Destination]
}
