import Foundation

enum EmailAddresses {
    static func normalize(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        return addresses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func isValid(_ address: String) -> Bool {
        address.range(of: #"^[^\s@,;<>]+@[^\s@,;<>]+$"#, options: .regularExpression) != nil
    }

    static func parse(_ text: String) -> [String]? {
        let addresses = normalize(text.components(separatedBy: CharacterSet(charactersIn: ",;\n\r")))
        return addresses.allSatisfy(isValid) ? addresses : nil
    }
}
