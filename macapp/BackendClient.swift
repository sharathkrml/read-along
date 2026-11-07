import AppKit

/// Thin HTTP client for the bundled Python backend.
struct BackendClient {
    var base: URL
    var session: URLSession = .shared

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func decode(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "The reading engine returned an invalid response.")
        }
        if json["ok"] as? Bool == false {
            throw Failure(message: json["error"] as? String ?? "The reading engine could not finish this action.")
        }
        return json
    }

    private static func throwFailure(_ data: Data?, _ status: Int) throws -> Never {
        var message = "Request failed (\(status))"
        if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let e = json["error"] as? String { message = e }
        throw Failure(message: message)
    }

    private func get(_ path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: base.appendingPathComponent("")) else {
            throw BackendClient.Failure(message: "Bad request path: \(path)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BackendClient.Failure(message: "No response")
        }
        guard http.statusCode == 200 else { try BackendClient.throwFailure(data, http.statusCode) }
        return data
    }

    func getJSON(_ path: String) async throws -> [String: Any] {
        try BackendClient.decode(try await get(path))
    }

    func post(_ path: String, body: [String: Any] = [:]) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: base.appendingPathComponent("")) else {
            throw BackendClient.Failure(message: "Bad request path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BackendClient.Failure(message: "No response")
        }
        guard (200..<300).contains(http.statusCode) else { try BackendClient.throwFailure(data, http.statusCode) }
        return try BackendClient.decode(data)
    }

    func imageData(_ name: String) async throws -> Data {
        try await get(name)
    }

    // Typed helpers

    func library() async throws -> LibraryPayload {
        try JSONDecoder().decode(LibraryPayload.self, from: try await get("library"))
    }

    func pageModel(docID: String? = nil) async throws -> PageModel {
        let path = docID.map { "model?doc_id=\($0)" } ?? "model"
        return try JSONDecoder().decode(PageModel.self, from: try await get(path))
    }

    func state() async throws -> ReaderState {
        try JSONDecoder().decode(ReaderState.self, from: try await get("state"))
    }

    func setupStatus() async throws -> SetupStatus {
        try JSONDecoder().decode(SetupStatus.self, from: try await get("setup/status"))
    }

    func importDocument(name: String, dataURL: String, mode: String) async throws -> Document? {
        let json = try await post("documents/import", body: ["name": name, "data": dataURL, "mode": mode])
        let response = try JSONDecoder().decode(ImportResponse.self, from: JSONSerialization.data(withJSONObject: json))
        guard response.ok == true, let document = response.document else {
            throw Failure(message: "The document was not confirmed by the reading engine. Please retry.")
        }
        return document
    }

    func openDocument(id: String) async throws {
        _ = try await post("documents/open", body: ["id": id])
    }

    func renameDocument(id: String, title: String) async throws {
        _ = try await post("documents/rename", body: ["id": id, "title": title])
    }

    func deleteDocument(id: String) async throws {
        _ = try await post("documents/delete", body: ["id": id])
    }

    private func documentBody(_ body: [String: Any], docID: String?) -> [String: Any] {
        var result = body
        if let docID { result["doc_id"] = docID }
        return result
    }

    func jump(word: Int, docID: String? = nil, revision: Int? = nil) async throws {
        var body = documentBody(["word": word], docID: docID)
        if let revision { body["revision"] = revision }
        _ = try await post("jump", body: body)
    }

    func saveScript(page: Int, text: String, docID: String? = nil) async throws -> PageModel {
        let json = try await post("script", body: documentBody(["page": page, "text": text], docID: docID))
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(ScriptResponse.self, from: data)
        guard decoded.ok == true, let model = decoded.model else {
            throw Failure(message: "The engine did not confirm the saved text. Your draft is still available.")
        }
        return model
    }

    func reOCR(fast: Bool, auto: Bool, docID: String? = nil) async throws {
        _ = try await post("ocr", body: documentBody(["fast": fast, "auto": auto], docID: docID))
    }

    func startFollow(docID: String? = nil) async throws {
        _ = try await post("start", body: documentBody([:], docID: docID))
    }

    func stopFollow(docID: String? = nil) async throws {
        _ = try await post("stop", body: documentBody([:], docID: docID))
    }

    func downloadModel(_ key: String) async throws {
        _ = try await post("setup/download", body: ["model": key])
    }

    func removeModel(_ key: String) async throws {
        _ = try await post("setup/remove", body: ["model": key])
    }

    func cancelModel(_ key: String) async throws {
        _ = try await post("setup/cancel", body: ["model": key])
    }

    func sourceData(docID: String) async throws -> Data {
        guard docID.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else {
            throw Failure(message: "Invalid document identity.")
        }
        return try await get("source/\(docID)")
    }

    func mics() async throws -> Microphones {
        try JSONDecoder().decode(Microphones.self, from: try await get("mics"))
    }

    func setMic(_ device: Int?) async throws {
        _ = try await post("mic", body: ["device": device ?? NSNull()])
    }

    func finishSetup() async throws {
        _ = try await post("setup/finish")
    }

    func exportJPEG(page: Int, mode: String = "proof", docID: String? = nil) async throws -> Data {
        guard ["read", "proof"].contains(mode) else { throw Failure(message: "Unknown export mode.") }
        let identity = docID.map { "&doc_id=\($0)" } ?? ""
        return try await imageData("export?mode=\(mode)&page=\(page)\(identity)")
    }

    func pageCount() async throws -> Int {
        try await state().model_pages ?? 0
    }
}
