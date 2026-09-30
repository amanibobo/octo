// Minimal stand-ins for app types the General pipeline references but the
// harness does not exercise (media cards, pinned context).
import Foundation

struct MediaCard {
    enum Kind: String {
        case paper
        case image
        case video
        case link
    }
}

struct UserContextBundle {
    let promptText: String
    let images: [ChatModelImage]
}
