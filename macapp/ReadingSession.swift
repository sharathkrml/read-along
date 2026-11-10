import Foundation

/// Shared UI enums and value types used across the SwiftUI shell.
///
/// ViewPane: which reader column is expanded (text / original / split).
/// Appearance: light / dark / system theme.
/// TransportState: the Follow me lifecycle (idle -> preparing -> playing|listening -> ...).
/// ZoomMode / ViewerState: per-document zoom and scroll preferences the
/// unified reader persists. Prefs: user settings persisted to UserDefaults.
/// ReadingMath: progress and page-anchor helpers shared by the UI.

enum ViewPane: String, Codable, CaseIterable {
    case text, original, split
}

enum PlaybackMode: String, Codable, CaseIterable {
    case follow
}

enum Appearance: String, Codable {
    case system, light, dark
}

enum TransportState: Equatable {
    case idle, preparing, playing, paused, listening, stopping, waitingForText, failed

    var isActive: Bool { self == .playing || self == .listening }
    var isBusy: Bool { self == .preparing || self == .stopping || self == .waitingForText }
}

enum ZoomMode: String, Codable, CaseIterable {
    case fitPage, fitWidth, actualSize, custom
}

struct ViewerState: Equatable {
    var browsedPage: Int? = nil
    var sourceFollows = true
    var textFollows = true
    var zoomMode: ZoomMode = .fitWidth
    var customScale: Double = 1
}

struct PageWordAnchor: Equatable {
    var documentID: String
    var page: Int
    var wordOffset: Int
}

struct DocumentViewPreferences: Codable {
    var zoomMode: ZoomMode = .fitWidth
    var customScale: Double = 1
}

struct Prefs: Codable, Equatable {
    var appearance: Appearance = .system
    var size: CGFloat = 20
    var guide = true
    var sound = false
    var haptic = false
    var pane: ViewPane = .text
    var ocrMode: String = "auto"
    var micName: String? = nil
    var readingFont: String? = "sans"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case appearance, size, guide, sound, haptic, pane, ocrMode, micName, readingFont
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appearance = (try? c.decode(Appearance.self, forKey: .appearance)) ?? .system
        let savedSize = (try? c.decode(Double.self, forKey: .size)) ?? 20
        size = CGFloat(min(32, max(16, savedSize.isFinite ? savedSize : 20)))
        guide = (try? c.decode(Bool.self, forKey: .guide)) ?? true
        sound = (try? c.decode(Bool.self, forKey: .sound)) ?? false
        haptic = (try? c.decode(Bool.self, forKey: .haptic)) ?? false
        pane = (try? c.decode(ViewPane.self, forKey: .pane)) ?? .text
        let savedOCR = (try? c.decode(String.self, forKey: .ocrMode)) ?? "auto"
        ocrMode = ["auto", "fast", "best"].contains(savedOCR) ? savedOCR : "auto"
        micName = try? c.decode(String.self, forKey: .micName)
        // Older installs used serif when this optional preference was absent.
        readingFont = (try? c.decode(String.self, forKey: .readingFont)) ?? "serif"
    }
}

enum ReadingMath {
    static func progress(position: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(position) / Double(total)))
    }

    /// Live progress is only trusted while the loaded model belongs to the
    /// document on screen; during a switch, use the library's saved position.
    static func progress(live: Bool, position: Int, total: Int,
                         savedPosition: Int, savedTotal: Int) -> Double {
        if live { return progress(position: position, total: total) }
        return progress(position: savedPosition, total: savedTotal)
    }

    static func anchor(documentID: String, position: Int, words: [Word]) -> PageWordAnchor? {
        guard !words.isEmpty else { return nil }
        let position = min(words.count, max(0, position))
        let page = words[min(position, words.count - 1)].page
        let offset = words.prefix(position).filter { $0.page == page }.count
        return PageWordAnchor(documentID: documentID, page: page, wordOffset: offset)
    }

    static func resolve(_ anchor: PageWordAnchor, words: [Word]) -> Int? {
        guard let first = words.firstIndex(where: { $0.page == anchor.page }) else { return nil }
        let count = words.filter { $0.page == anchor.page }.count
        return min(words.count, first + min(count, max(0, anchor.wordOffset)))
    }

    /// Index of the word closest to a normalized page point, or nil when no
    /// word is within `slack` of it. Used by clicks on the original page.
    static func word(at point: CGPoint, page: Int, words: [Word], slack: CGFloat = 0.05) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, word) in words.enumerated() where word.page == page {
            guard let box = word.box, box.count == 4 else { continue }
            let x0 = CGFloat(box[0]), y0 = CGFloat(box[1])
            let x1 = x0 + CGFloat(box[2]), y1 = y0 + CGFloat(box[3])
            let dx = max(0, max(x0 - point.x, point.x - x1))
            let dy = max(0, max(y0 - point.y, point.y - y1))
            let distance = hypot(dx, dy)
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        guard let best, best.distance <= slack else { return nil }
        return best.index
    }
}

enum PreparationReason: String, Codable, CaseIterable, Equatable {
    case voice
    case speechEngine
    case permission
    case nextPage
    case documentOpen
    case textLoad
    case previewLoad
}

enum DocumentLoadPhase: String, Codable, Equatable {
    case idle
    case acknowledging
    case opening
    case loadingText
    case loadingPreview
    case failed
    case completed
}

struct DocumentLoadState: Equatable {
    var documentID: String
    var generation: Int
    var phase: DocumentLoadPhase = .idle
    var title: String = ""
    var detail: String = ""
    var progress: Double? = nil
    var error: String? = nil

    var isIndeterminate: Bool { progress == nil }
}

struct LoadingStatus: Equatable {
    var title: String
    var detail: String
    var progress: Double? = nil
    var isIndeterminate: Bool { progress == nil }
    var actions: [String] = []

    static func indeterminate(title: String, detail: String, actions: [String] = []) -> LoadingStatus {
        LoadingStatus(title: title, detail: detail, progress: nil, actions: actions)
    }
}

enum LoadingMath {
    static func clampedProgress(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return min(1, max(0, value))
    }
}

struct TransportPresentation: Equatable {
    var label: String
    var icon: String
    var enabled: Bool
    var busy: Bool
}
