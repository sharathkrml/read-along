import Foundation

// Assert-based native checks, compiled by scripts/test_native.sh into a
// standalone executable together with the non-app-entry sources
// (Models.swift, ReadingSession.swift). This file lives in macapp/Tests/ so the
// app bundle's macapp/*.swift glob never picks up this second @main.
//
// Usage: NativeChecks <fixtures-dir>   (fixtures from make_fixtures.py)

var failures = 0

func check(_ name: String, _ condition: Bool) {
    if condition {
        print("ok  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

func checkEqual<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    if got == want {
        print("ok  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name): got \(got), want \(want)")
    }
}

func checkThrows<T>(_ name: String, _ body: () throws -> T) {
    do {
        _ = try body()
        failures += 1
        print("FAIL  \(name): expected a throw")
    } catch {
        print("ok  \(name)")
    }
}

func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

@main
struct NativeChecks {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            print("usage: NativeChecks <fixtures-dir>")
            exit(2)
        }
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        runChecks(fixtures: fixtures)
        if failures > 0 {
            print("\(failures) native check(s) failed")
            exit(1)
        }
        print("all native checks passed")
    }

    static func runChecks(fixtures: URL) {
        decoderChecks()
        mathChecks()
        loadingChecks()
        transformChecks()
        fixtureModelChecks(fixtures: fixtures)
    }

    // MARK: decoder assertions: current payloads and safe empty payloads

    static func decoderChecks() {
        // Library: the backend's canonical empty payload and a representative
        // current payload. Note: a bare {} currently throws (documents is a
        // required key); tightening that is a later card's behavior change.
        let emptyLibrary = try! decode(LibraryPayload.self, "{\"active\": null, \"documents\": []}")
        checkEqual("library empty active", emptyLibrary.active, nil)
        checkEqual("library empty documents", emptyLibrary.documents.count, 0)
        checkThrows("library bare {} rejected today") { try decode(LibraryPayload.self, "{}") }

        let library = try! decode(LibraryPayload.self, """
        {"active": "doc-1", "future_field": true, "documents": [{
            "id": "doc-1", "title": "Talk.pdf", "file_name": "Talk.pdf",
            "status": "ready", "position": 3, "total": 10, "pages": 2,
            "ocr_done": 1, "ocr_total": 2, "ocr_phase": "recognition"
        }]}
        """)
        checkEqual("library active", library.active, "doc-1")
        checkEqual("library doc status", library.documents.first?.statusName, "ready")
        checkEqual("library doc progress fields", library.documents.first?.wordPosition, 3)
        checkEqual("library doc ocr phase", library.documents.first?.ocr_phase, "recognition")

        // Model: safe empty payload, a representative payload, and malformed JSON.
        let emptyModel = try! decode(PageModel.self, "{}")
        check("model empty is empty", emptyModel.isEmpty)
        checkEqual("model empty identity", emptyModel.doc_id, nil)

        let model = try! decode(PageModel.self, """
        {"doc_id": "doc-1", "model_revision": 7,
         "pages": [{"width": 612, "height": 792, "image": "p000.png",
                    "reading_status": "ready", "rotation": 90}],
         "lines": [{"page": 0, "text": "hello world", "box": [1, 2, 3, 4],
                    "tokens": [{"text": "hello", "norm": "hello", "w": 0, "box": null},
                               {"text": "world", "norm": "world", "w": 1, "box": [5, 6, 7, 8]}]}],
         "words": [{"text": "hello", "norm": "hello", "page": 0, "line": 0, "box": null},
                   {"text": "world", "norm": "world", "page": 0, "line": 0, "box": [5, 6, 7, 8]}],
         "groups": [{"page": 0, "start": 0, "end": 2}]}
        """)
        checkEqual("model doc id", model.doc_id, "doc-1")
        checkEqual("model revision", model.model_revision, 7)
        checkEqual("model page status", model.pages.first?.reading_status, "ready")
        checkEqual("model page rotation", model.pages.first?.rotation, 90)
        checkEqual("model words", model.words.count, 2)
        checkEqual("model group", model.groups.first, AlignGroup(page: 0, start: 0, end: 2))
        check("model null box decodes", model.words[0].box == nil)
        checkThrows("model malformed pages") { try decode(PageModel.self, #"{"pages": "nope"}"#) }

        // State: empty payload and a representative payload.
        let emptyState = try! decode(ReaderState.self, "{}")
        checkEqual("state empty pos", emptyState.pos, nil)
        checkEqual("state empty heard", emptyState.heard, nil)
        let state = try! decode(ReaderState.self, """
        {"doc_id": "doc-1", "model_revision": 7, "status": "idle", "pos": 3, "heard": 7,
         "total": 10, "page": 0, "confidence": 0.5, "ocr_done": 1, "ocr_total": 2,
         "speech_ready": true, "ocr_ready": false, "model_ready": true}
        """)
        checkEqual("state doc id", state.doc_id, "doc-1")
        checkEqual("state position", state.pos, 3)
        checkEqual("state heard", state.heard, 7)
        checkEqual("state ocr done", state.ocr_done, 1)
        checkEqual("state speech ready", state.speech_ready, true)

        // Setup status: empty and a downloading example with truthful extras.
        let emptySetup = try! decode(SetupStatus.self, "{}")
        checkEqual("setup empty first_run", emptySetup.first_run, nil)
        let setup = try! decode(SetupStatus.self, """
        {"first_run": false,
         "speech": {"state": "downloading", "bytes": 50, "total": 100,
                    "can_cancel": true, "progress_is_approximate": true},
         "ocr": {"state": "ready"}}
        """)
        checkEqual("setup speech state", setup.speech?.state, "downloading")
        checkEqual("setup speech cancellable", setup.speech?.can_cancel, true)
        checkEqual("setup ocr state", setup.ocr?.state, "ready")

        // Microphones use the "default" coding key.
        let mics = try! decode(Microphones.self, """
        {"default": 1, "devices": [{"id": 0, "name": "Built-in", "channels": 2},
                                   {"id": 1, "name": "USB Mic", "channels": 1}]}
        """)
        checkEqual("microphone default", mics.defaultDevice, 1)
        checkEqual("microphone count", mics.devices.count, 2)

        // Preferences: defaults from empty payload, backward compatibility, clamping.
        let defaults = try! decode(Prefs.self, "{}")
        checkEqual("prefs default size", defaults.size, 20)
        checkEqual("prefs default guide", defaults.guide, true)
        checkEqual("prefs default ocr mode", defaults.ocrMode, "auto")
        checkEqual("prefs default font is legacy serif", defaults.readingFont, "serif")
        checkEqual("prefs default pane", defaults.pane, .text)

        let legacy = try! decode(Prefs.self, #"{"size": 24, "voice": "Samantha"}"#)
        checkEqual("prefs legacy font fallback", legacy.readingFont, "serif")
        checkEqual("prefs legacy size", legacy.size, 24)

        let clamped = try! decode(Prefs.self, #"{"size": 100, "ocrMode": "turbo"}"#)
        checkEqual("prefs size clamped", clamped.size, 32)
        checkEqual("prefs unknown ocr mode falls back", clamped.ocrMode, "auto")
        let clampedLow = try! decode(Prefs.self, #"{"size": 4}"#)
        checkEqual("prefs size floor", clampedLow.size, 16)
        let badEnums = try! decode(Prefs.self, #"{"pane": "bogus"}"#)
        checkEqual("prefs unknown pane falls back", badEnums.pane, .text)
    }

    // MARK: cursor/progress math

    static func mathChecks() {
        checkEqual("progress empty text", ReadingMath.progress(position: 0, total: 0), 0)
        checkEqual("progress at start", ReadingMath.progress(position: 0, total: 10), 0)
        checkEqual("progress mid", ReadingMath.progress(position: 3, total: 10), 0.3)
        checkEqual("progress complete", ReadingMath.progress(position: 10, total: 10), 1)
        checkEqual("progress clamps high", ReadingMath.progress(position: 15, total: 10), 1)
        checkEqual("progress clamps low", ReadingMath.progress(position: -5, total: 10), 0)

        func word(_ text: String, _ page: Int) -> Word {
            Word(text: text, norm: text.lowercased(), page: page, line: page, box: nil)
        }
        let partial = ["later", "page", "becomes", "ready", "first"].map { word($0, 2) }
        let anchor = ReadingMath.anchor(documentID: "doc", position: 3, words: partial)
        checkEqual("anchor page", anchor?.page, 2)
        checkEqual("anchor offset", anchor?.wordOffset, 3)
        let completed = ["scan", "one", "recovered", "text"].map { word($0, 0) }
            + ["scan", "two", "more", "recovered", "words", "here"].map { word($0, 1) }
            + partial
        let resolved = ReadingMath.resolve(PageWordAnchor(documentID: "doc", page: 2, wordOffset: 3), words: completed)
        checkEqual("rebased index shifts by inserted words", resolved, 13)
        checkEqual("rebased word is the same word", resolved.map { completed[$0].text }, "ready")
        checkEqual("anchor of empty model", ReadingMath.anchor(documentID: "doc", position: 0, words: []), nil)
        checkEqual("resolve of missing page",
                   ReadingMath.resolve(PageWordAnchor(documentID: "doc", page: 9, wordOffset: 0), words: completed), nil)
        checkEqual("resolve clamps overflowing offset",
                   ReadingMath.resolve(PageWordAnchor(documentID: "doc", page: 2, wordOffset: 99), words: completed),
                   completed.count)
    }

    // MARK: mixed-readiness fixture (generated, no AI model involved)

    static func loadingChecks() {
        let state = DocumentLoadState(documentID: "doc-1", generation: 1, phase: .opening, title: "Opening", detail: "Loading saved text…", progress: nil)
        check("document load indeterminate", state.isIndeterminate)
        let progressed = DocumentLoadState(documentID: "doc-1", generation: 1, phase: .loadingText, title: "Opening", detail: "Loading", progress: 1.2)
        checkEqual("progress clamped", LoadingMath.clampedProgress(progressed.progress), 1.0)
        let status = LoadingStatus.indeterminate(title: "Preparing voice…", detail: "Starting", actions: ["Stop"])
        check("loading status indeterminate", status.isIndeterminate)
        checkEqual("loading status actions", status.actions, ["Stop"])
        checkEqual("preparation reason raw", PreparationReason.voice.rawValue, "voice")
    }

    static func transformChecks() {
        var t = SourceViewerTransform(scale: 2.5, origin: CGPoint(x: 10, y: -4))
        let p = CGPoint(x: 100, y: 200)
        let rt = t.roundTrip(p)
        check("transform round trip x", abs(rt.x - p.x) < 0.0001)
        check("transform round trip y", abs(rt.y - p.y) < 0.0001)
        check("screen stroke constant", t.screenStrokeWidth(base: 3) == 3)
    }

    static func fixtureModelChecks(fixtures: URL) {
        func loadModel(_ name: String) -> PageModel? {
            guard let data = try? Data(contentsOf: fixtures.appendingPathComponent(name)) else { return nil }
            return try? JSONDecoder().decode(PageModel.self, from: data)
        }
        guard let partial = loadModel("mixed_readiness_model.json"),
              let completed = loadModel("mixed_readiness_completed_model.json") else {
            failures += 1
            print("FAIL  mixed-readiness fixtures decode")
            return
        }
        print("ok  mixed-readiness fixtures decode")
        checkEqual("partial statuses", partial.pages.map { $0.reading_status }, ["pending", "pending", "ready"])
        checkEqual("completed statuses", completed.pages.map { $0.reading_status }, ["ready", "ready", "ready"])
        check("revision increases", (completed.model_revision ?? 0) > (partial.model_revision ?? 0))

        // Read on the ready later page, then earlier pages finish: the anchor
        // must rebase onto the same word instead of a stale numeric index.
        let position = 3  // fourth word of the ready page ("ready")
        checkEqual("fixture word at anchor", partial.words[position].text, "ready")
        let anchor = ReadingMath.anchor(documentID: partial.doc_id ?? "", position: position, words: partial.words)
        checkEqual("fixture anchor page", anchor?.page, 2)
        checkEqual("fixture anchor offset", anchor?.wordOffset, 3)
        let resolved = anchor.flatMap { ReadingMath.resolve($0, words: completed.words) }
        checkEqual("fixture rebased word", resolved.map { completed.words[$0].text }, "ready")
        checkEqual("fixture rebased index", resolved, 4 + 6 + 3)
    }
}
