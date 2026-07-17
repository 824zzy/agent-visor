public enum CodexUnixSocketConnectionMatcher {
    public static func hasConnection(
        processIDs: Set<Int>,
        socketPath: String,
        lsofFields: String
    ) -> Bool {
        let records = parse(lsofFields)
        let serverDevices = Set(records.compactMap { record in
            record.name == socketPath ? record.device?.lowercased() : nil
        })
        guard !serverDevices.isEmpty else { return false }

        return records.contains { record in
            guard processIDs.contains(record.processID),
                  let name = record.name,
                  name.hasPrefix("->") else { return false }
            return serverDevices.contains(String(name.dropFirst(2)).lowercased())
        }
    }

    private struct FileRecord {
        let processID: Int
        let device: String?
        let name: String?
    }

    private static func parse(_ output: String) -> [FileRecord] {
        var records: [FileRecord] = []
        var processID: Int?
        var hasFile = false
        var device: String?
        var name: String?

        func appendCurrent() {
            guard hasFile, let processID else { return }
            records.append(FileRecord(processID: processID, device: device, name: name))
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                appendCurrent()
                processID = Int(value)
                hasFile = false
                device = nil
                name = nil
            case "f":
                appendCurrent()
                hasFile = true
                device = nil
                name = nil
            case "d":
                device = value
            case "n":
                name = value
            default:
                break
            }
        }
        appendCurrent()
        return records
    }
}
