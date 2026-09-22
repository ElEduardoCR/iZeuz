import Foundation

final class WorkshopURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var primaryDown = false
    nonisolated(unsafe) static var requests: [(String, String)] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url!.host!
        let path = request.url!.path
        let down = Self.lock.withLock { () -> Bool in
            Self.requests.append((host, request.httpMethod! + " " + path))
            return Self.primaryDown && host == "pc.invalid"
        }
        if down {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let body: String
        if path == "/v1/workshop" {
            body = #"{"server_url":"http://pi.invalid:5000"}"#
        } else if path.hasPrefix("/v1/dnc/update/") {
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            body = #"{"supported":true,"available":true,"phase":"waiting_idle","current_version":"0.6.0","latest_version":"0.7.0","latest_revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","auto_install":false}"#
        } else if path == "/v1/dnc/machines" {
            body = #"[{"id":"lathe","name":"Torno","revision":7,"baudrate":19200,"bytesize":8,"parity":"N","stopbits":1,"flow_control":"none","line_terminator":"CRLF"}]"#
        } else if path == "/v1/dnc/machine/save" {
            body = #"{"ok":true,"machine":{"id":"lathe","name":"Torno editado","revision":8,"baudrate":4800,"bytesize":8,"parity":"N","stopbits":1,"flow_control":"none","line_terminator":"CRLF"}}"#
        } else if path == "/v1/programs/search" {
            body = #"{"results":[{"name":"O1.nc","path":"old/O1.nc","kind":"file","size":12,"modified":1000},{"name":"O3.nc","path":"new/O3.nc","kind":"file","size":12,"modified":3000},{"name":"O2.nc","path":"unknown/O2.nc","kind":"file","size":12,"modified":null}]}"#
        } else if path == "/v1/programs" {
            body = #"{"path":"","parent":null,"entries":[{"name":"O1.nc","path":"O1.nc","kind":"file","size":12,"modified":1000}],"version":1}"#
        } else {
            body = #"{"ok":true}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body.data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct WorkshopClientTests {
    static func verifyProgramOrdering() {
        func entry(_ name: String, _ timestamp: TimeInterval?, path: String? = nil) -> ProgramEntry {
            ProgramEntry(name: name, path: path ?? name, isDirectory: false, size: 12,
                         modified: timestamp.map { Date(timeIntervalSince1970: $0) })
        }
        let input = [entry("O1.nc", 10), entry("O10.nc", 20), entry("O2.nc", 20),
                     entry("O0.nc", nil), entry("O9.nc", nil),
                     entry("O2.nc", 20, path: "b/O2.nc"), entry("O2.nc", 20, path: "a/O2.nc")]
        let original = input
        let recent = ProgramSortOrder.latestUpdated.sorted(input)
        precondition(recent.map(\.path) == ["a/O2.nc", "b/O2.nc", "O2.nc", "O10.nc", "O1.nc", "O0.nc", "O9.nc"])
        precondition(ProgramSortOrder.latestUpdated.sorted(Array(input.reversed())) == recent)
        precondition(ProgramSortOrder.name.sorted(input).map(\.name) == ["O0.nc", "O1.nc", "O2.nc", "O2.nc", "O2.nc", "O9.nc", "O10.nc"])
        precondition(ProgramSortOrder.latestUpdated.sorted([]).isEmpty)
        precondition(ProgramSortOrder.latestUpdated.sorted([input[0]]) == [input[0]])
        precondition(input == original)
        let folders = [ProgramEntry(name: "Work", path: "Work", isDirectory: true, size: 0, modified: nil)]
        let listing = DirectoryListing(path: "", breadcrumb: [], directories: folders, files: input)
        _ = ProgramSortOrder.latestUpdated.sorted(listing.files)
        precondition(listing.directories == folders && listing.files == input)
    }

    static func main() async throws {
        verifyProgramOrdering()
        URLProtocol.registerClass(WorkshopURLProtocol.self)
        let primary = "http://pc.invalid:47820"
        let fallbackKey = "zeuz.workshop.fallback:" + primary
        let activeKey = "zeuz.workshop.active:" + primary
        UserDefaults.standard.removeObject(forKey: fallbackKey)
        UserDefaults.standard.removeObject(forKey: activeKey)
        defer {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
            UserDefaults.standard.removeObject(forKey: activeKey)
            URLProtocol.unregisterClass(WorkshopURLProtocol.self)
        }
        let settings = ZeuzAgentSettings(baseURL: primary)
        let client = ZeuzAgentProgramClient(settings: settings, token: "test-token")
        try await client.checkConnection()
        precondition(UserDefaults.standard.string(forKey: fallbackKey) == "http://pi.invalid:5000")
        WorkshopURLProtocol.lock.withLock { WorkshopURLProtocol.primaryDown = true }
        let listing = try await client.list(path: "")
        precondition(listing.files.first?.name == "O1.nc")
        precondition(listing.files.first?.modified == Date(timeIntervalSince1970: 1000))
        // Active search uses the same order and the actual server modification dates.
        let results = try await client.search(query: ".nc", limit: 300)
        precondition(ProgramSortOrder.latestUpdated.sorted(results).map(\.path) == ["new/O3.nc", "old/O1.nc", "unknown/O2.nc"])
        precondition(results[1].modified == Date(timeIntervalSince1970: 3000))
        precondition(results[2].modified == nil)
        precondition(UserDefaults.standard.string(forKey: activeKey) == "http://pi.invalid:5000")
        // New actors used by AppModel must retain the selected live destination.
        let reconnected = ZeuzAgentProgramClient(settings: settings, token: "test-token")
        let profiles = try await reconnected.machines()
        var machine = profiles[0].asMachine
        precondition(machine.revision == 7)
        machine.baudRate = 4800
        let saved = try await reconnected.saveMachine(machine, isNew: false)
        precondition(saved.revision == 8 && saved.baudRate == 4800)
        let updateClient: any ZeuzDNCClient = reconnected
        let update = try await updateClient.update(machineID: "lathe", action: "status")
        precondition(update.supported == true && update.isBusy && update.latest_version == "0.7.0")
        _ = try await updateClient.update(machineID: "lathe", action: "install", revision: update.latest_revision, requestID: UUID().uuidString, autoInstall: nil)
        // A failed POST may already have reached the CNC. Never replay it.
        UserDefaults.standard.removeObject(forKey: activeKey)
        let uncertain = ZeuzAgentProgramClient(settings: settings, token: "test-token")
        do {
            try await uncertain.send(path: "O1.nc", machineID: "lathe")
            preconditionFailure("Expected uncertain-write error")
        } catch {}
        // An uncertain OTA request is never replayed on a second device either.
        UserDefaults.standard.removeObject(forKey: activeKey)
        let uncertainUpdate = ZeuzAgentProgramClient(settings: settings, token: "test-token")
        let before = WorkshopURLProtocol.lock.withLock { WorkshopURLProtocol.requests.filter { $0.0 == "pi.invalid" && $0.1 == "POST /v1/dnc/update/install" }.count }
        do {
            _ = try await uncertainUpdate.update(machineID: "lathe", action: "install", revision: update.latest_revision, requestID: UUID().uuidString, autoInstall: nil)
            preconditionFailure("Expected uncertain OTA error")
        } catch {}
        let after = WorkshopURLProtocol.lock.withLock { WorkshopURLProtocol.requests.filter { $0.0 == "pi.invalid" && $0.1 == "POST /v1/dnc/update/install" }.count }
        precondition(before == after)
        let calls = WorkshopURLProtocol.lock.withLock { WorkshopURLProtocol.requests }
        precondition(!calls.contains { $0.0 == "pi.invalid" && $0.1 == "POST /v1/dnc/send" })
        print("PASS: newest-first/name ordering, ties, missing dates, server timestamps, active search and unchanged entries")
        print("PASS: mobile failover, persisted routing, profile revisions authenticated OTA decoding and no replay of uncertain sends/updates")
    }
}
