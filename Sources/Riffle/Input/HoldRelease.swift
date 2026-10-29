import Foundation

/// What letting go of a shortcut's hold key does.
enum ReleaseBehavior: String, Codable, CaseIterable {
    /// Switch to the selected window (the switcher's classic way).
    case switchToSelected
    /// The switcher stays up: ↩ or a click switches, ⎋ closes.
    case keepOpen
    /// The switcher stays up and starts searching.
    case keepOpenAndSearch

    init(from decoder: Decoder) throws {
        // A value from a newer version falls back to the classic behaviour rather than losing the whole shortcut.
        self = ReleaseBehavior(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .switchToSelected
    }
}

/// The part of a switcher session that the hold key going up changes, and what the switcher should do about it.
/// Pure state, so the transitions can be tested without a keyboard.
struct HoldRelease: Equatable {
    /// Stays open after the hold key goes up (search, opened from the menu bar, or kept open on release).
    var isSticky: Bool
    var isSearching: Bool
    /// The hold key has gone up: from now on ⌘V pastes and ⌥ types its symbols again.
    var isReleased = false

    enum Effect: Equatable {
        /// Nothing to do (already released, or the session stays open anyway).
        case none
        case switchToSelection
        /// Show the panel right away if it isn't up yet, and keep it.
        case stayOpen
        /// Keep the panel and turn on search.
        case startSearching
    }

    /// The hold key went up: at the summon itself (a quick tap, the key already up) or any time later.
    mutating func release(_ behavior: ReleaseBehavior) -> Effect {
        guard !isReleased else { return .none }
        isReleased = true
        if isSticky { return .none }
        switch behavior {
        case .switchToSelected:
            return .switchToSelection
        case .keepOpen:
            isSticky = true
            return .stayOpen
        case .keepOpenAndSearch:
            isSticky = true
            if isSearching { return .stayOpen }
            isSearching = true
            return .startSearching
        }
    }
}
