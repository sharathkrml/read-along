import Foundation

// Codable mirrors of the JSON the bundled Python backend serves. The server is
// the source of truth; these structs only shape it for the UI.

struct LibraryPayload: Decodable, Equatable {
    var active: String?
    var documents: [Document]

    init(active: String? = nil, documents: [Document] = []) {
        self.active = active
        self.documents = documents
    }
}

struct Document: Decodable, Identifiable, Equatable {
    var id: String
    var title: String
    var file_name: String?
    var source: String?
    var status: String?
    var error: String?
    var created: Double?
    var last_opened: Double?
    var position: Int?
    var total: Int?
    var pages: Int?
    var ocr_done: Int?
    var ocr_total: Int?
    var ocr_phase: String?

    var statusName: String { status ?? "idle" }
    var pageCount: Int { pages ?? 0 }
    var wordTotal: Int { total ?? 0 }
    var wordPosition: Int { position ?? 0 }
    var errorMessage: String { error ?? "" }
}

struct PageModel: Decodable, Equatable {
    var doc_id: String? = nil
    var model_revision: Int? = nil
    var pages: [PageInfo] = []
    var lines: [Line] = []
    var words: [Word] = []
    var groups: [AlignGroup] = []

    init(pages: [PageInfo] = [], lines: [Line] = [], words: [Word] = [], groups: [AlignGroup] = []) {
        self.pages = pages
        self.lines = lines
        self.words = words
        self.groups = groups
    }

    private enum CodingKeys: String, CodingKey { case pages, lines, words, groups, doc_id, model_revision }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        doc_id = try c.decodeIfPresent(String.self, forKey: .doc_id)
        model_revision = try c.decodeIfPresent(Int.self, forKey: .model_revision)
        pages = try c.decodeIfPresent([PageInfo].self, forKey: .pages) ?? []
        lines = try c.decodeIfPresent([Line].self, forKey: .lines) ?? []
        words = try c.decodeIfPresent([Word].self, forKey: .words) ?? []
        groups = try c.decodeIfPresent([AlignGroup].self, forKey: .groups) ?? []
    }

    var isEmpty: Bool { words.isEmpty }
}

struct PageInfo: Decodable, Equatable {
    var width: Double
    var height: Double
    var image: String?
    var reading_status: String? = nil
    var error: String? = nil
    var rotation: Int? = nil
}

struct Line: Decodable, Equatable {
    var page: Int
    var text: String
    var box: [Double]?
    var tokens: [Token]
    var exact: Bool?
    var kind: String?
    var block: Int?
    var sep: String?
}

struct Token: Decodable, Equatable {
    var text: String
    var norm: String?
    var w: Int?
    var box: [Double]?
}

struct Word: Decodable, Equatable {
    var text: String
    var norm: String?
    var page: Int
    var line: Int
    var box: [Double]?
}

struct AlignGroup: Decodable, Equatable {
    var page: Int
    var start: Int
    var end: Int
}

struct ReaderState: Decodable, Equatable {
    var doc_id: String? = nil
    var model_revision: Int? = nil
    var speech_engine_status: String? = nil
    var status: String? = nil
    var error: String? = nil
    var partial: String? = nil
    var rms: Double? = nil
    var ocr_status: String? = nil
    var ocr_error: String? = nil
    var ocr_done: Int? = nil
    var ocr_total: Int? = nil
    var ocr_phase: String? = nil
    var ocr_page: Int? = nil
    var required_model: String? = nil
    var model_ready: Bool? = nil
    var model_words: Int? = nil
    var model_pages: Int? = nil
    var speech_ready: Bool? = nil
    var ocr_ready: Bool? = nil
    var pos: Int? = nil
    var total: Int? = nil
    var page: Int? = nil
    var confidence: Double? = nil
}

struct SetupStatus: Decodable, Equatable {
    var first_run: Bool? = nil
    var speech: ModelStatus? = nil
    var ocr: ModelStatus? = nil

    init() { }
}

struct Microphone: Decodable, Identifiable, Equatable, Hashable {
    var id: Int
    var name: String
    var channels: Int
}

struct Microphones: Decodable, Equatable {
    var defaultDevice: Int?
    var devices: [Microphone]

    private enum CodingKeys: String, CodingKey {
        case defaultDevice = "default"
        case devices
    }

    init(defaultDevice: Int? = nil, devices: [Microphone] = []) {
        self.defaultDevice = defaultDevice
        self.devices = devices
    }
}

struct ModelStatus: Decodable, Equatable {
    var state: String? = nil
    var bytes: Double? = nil
    var total: Double? = nil
    var path: String? = nil
    var error: String? = nil
    var can_cancel: Bool? = nil
    var progress_is_approximate: Bool? = nil
}

struct ImportResponse: Decodable {
    var ok: Bool?
    var document: Document?
}

struct RenameResponse: Decodable {
    var ok: Bool?
    var document: Document?
}

struct ScriptResponse: Decodable {
    var ok: Bool?
    var model: PageModel?
}
