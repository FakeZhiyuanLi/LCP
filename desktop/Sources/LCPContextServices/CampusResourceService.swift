import Foundation
import CoreGraphics

/// A class-scoped link to a UCI service that does not expose a stable student
/// API.  The validator strips transient query strings such as Zoom meeting
/// passwords before the address is saved in the local library.
public struct UciCampusLink: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case piazza
        case zoom

        public var label: String {
            switch self {
            case .piazza: "Piazza"
            case .zoom: "UCI Zoom"
            }
        }

        public var helpURL: URL {
            switch self {
            case .piazza: URL(string: "https://piazza.com/")!
            case .zoom: URL(string: "https://uci.zoom.us/")!
            }
        }
    }

    public let kind: Kind
    public let url: URL

    public init(kind: Kind, address: String) throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: address),
              parts.scheme?.lowercased() == "https",
              parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil,
              let host = parts.host?.lowercased(),
              !parts.percentEncodedPath.isEmpty,
              Self.isAllowed(host: host, path: parts.percentEncodedPath, kind: kind) else {
            throw UniversityServiceError.message("Paste a valid HTTPS \(kind.label) course or meeting link.")
        }

        var canonical = URLComponents()
        canonical.scheme = "https"
        canonical.host = host
        canonical.path = parts.path
        guard let url = canonical.url else {
            throw UniversityServiceError.message("The \(kind.label) address is invalid.")
        }
        self.kind = kind
        self.url = url
    }

    private static func isAllowed(host: String, path: String, kind: Kind) -> Bool {
        func hasIdentifier(after prefix: String) -> Bool {
            guard path.hasPrefix(prefix) else { return false }
            let remainder = String(path.dropFirst(prefix.count))
            // Keep the stable resource path, but reject a bare service route or
            // an empty first segment such as `/class//123`.
            guard let first = remainder.split(separator: "/", omittingEmptySubsequences: true).first,
                  !first.isEmpty else { return false }
            return !remainder.hasPrefix("/")
        }
        switch kind {
        case .piazza:
            guard host == "piazza.com" || host == "www.piazza.com" else { return false }
            return hasIdentifier(after: "/class/") || hasIdentifier(after: "/course/")
        case .zoom:
            guard host == "uci.zoom.us" || host == "zoom.us" || host == "www.zoom.us" else { return false }
            return hasIdentifier(after: "/j/") || hasIdentifier(after: "/my/") || hasIdentifier(after: "/wc/")
        }
    }
}

public struct GradescopeResource: Equatable, Sendable {
    public let url: URL
    public let isAssignment: Bool

    /// Store only the persistent resource path. Login parameters and page fragments are transient.
    public init(address: String) throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: address),
              parts.scheme?.lowercased() == "https",
              ["gradescope.com", "www.gradescope.com"].contains(parts.host?.lowercased() ?? ""),
              parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil,
              parts.percentEncodedPath.range(of: #"^/(courses/[0-9]+(/assignments/[0-9]+(/submissions/[0-9]+)?)?|assignments/[0-9]+(/submissions/[0-9]+)?)/?\z"#, options: .regularExpression) != nil
        else { throw UniversityServiceError.message("Paste the HTTPS address of a Gradescope course, assignment, or submission.") }
        var path = parts.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        guard let url = URL(string: "https://www.gradescope.com" + path) else {
            throw UniversityServiceError.message("The Gradescope address is invalid.")
        }
        self.url = url
        self.isAssignment = path.contains("/assignments/")
    }

    public func gradedPDF(at file: URL) throws -> UniversityDocument {
        guard isAssignment else {
            throw UniversityServiceError.message("Paste the Gradescope assignment or submission address for this graded copy.")
        }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let limit = MaterialService.maximumOriginalBytes
        guard file.isFileURL, file.pathExtension.lowercased() == "pdf", values.isRegularFile == true,
              let size = values.fileSize, size > 0, size <= limit else {
            throw UniversityServiceError.message("Choose a downloaded PDF up to 32 MiB.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= limit {
            let request = min(65_536, limit + 1 - data.count)
            guard let part = try handle.read(upToCount: request), !part.isEmpty else { break }
            data.append(part)
        }
        guard data.count == size, data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil,
              let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider),
              pdf.numberOfPages > 0 || (pdf.isEncrypted && !pdf.isUnlocked) else {
            throw UniversityServiceError.message("The selected file does not contain a complete, readable PDF download.")
        }
        return UniversityDocument(filename: file.lastPathComponent, data: data, sourceURL: url)
    }
}

public enum UciTerm: String, CaseIterable, Sendable {
    case winter = "03", spring = "14", summer1 = "25", summer10 = "39", summerMedicine = "51"
    case summer2 = "76", fall = "92", springLaw = "0S", fallLaw = "8F"

    public var label: String {
        switch self {
        case .winter: "Winter"
        case .spring: "Spring"
        case .summer1: "Summer Session 1"
        case .summer10: "10-week Summer"
        case .summerMedicine: "Summer Quarter (COM)"
        case .summer2: "Summer Session 2"
        case .fall: "Fall"
        case .springLaw: "Spring Semester (Law)"
        case .fallLaw: "Fall Semester (Law)"
        }
    }
}

public struct UciRegistrarQuery: Equatable, Sendable {
    public let department: String
    public let courseNumber: String
    public let year: Int
    public let term: UciTerm

    public init(department: String, courseNumber: String, year: Int, term: UciTerm) throws {
        let dept = department.split(whereSeparator: \.isWhitespace).joined(separator: " ").uppercased()
        let number = courseNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard (1900...2100).contains(year),
              dept.range(of: #"^[A-Z][A-Z0-9 &-]{0,19}\z"#, options: .regularExpression) != nil,
              dept != "ALL",
              number.range(of: #"^[A-Z]{0,3}[0-9]{1,3}[A-Z]{0,3}\z"#, options: .regularExpression) != nil else {
            throw UniversityServiceError.message("Enter a UCI department code and one course number, such as I&C SCI and 46.")
        }
        self.department = dept == "ICS" ? "I&C SCI" : dept
        self.courseNumber = number
        self.year = year
        self.term = term
    }

    public var title: String { "\(department) \(courseNumber) · \(term.label) \(year) schedule" }
    public var remoteID: String { "\(year)-\(term.rawValue)/\(department)/\(courseNumber)" }
    public func url(text: Bool = false) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "www.reg.uci.edu"
        parts.path = "/perl/WebSoc"
        var query = [URLQueryItem(name: "YearTerm", value: "\(year)-\(term.rawValue)"),
                     URLQueryItem(name: "Dept", value: department),
                     URLQueryItem(name: "CourseNum", value: courseNumber)]
        if text { query.append(URLQueryItem(name: "Submit", value: "Display Text Results")) }
        parts.queryItems = query
        return parts.url!
    }

    public func load(using http: UniversityHTTP = .init()) async throws -> UniversityDocument {
        let (data, response) = try await http.get(url(text: true), allowedHosts: ["www.reg.uci.edu"], limit: 1_048_576)
        guard response.mimeType == "text/plain", let text = String(data: data, encoding: .isoLatin1),
              text.contains("UC Irvine Office of the Registrar"), text.contains("Schedule of Classes") else {
            throw UniversityServiceError.message("The Registrar did not return its text schedule. Open WebSOC to check availability.")
        }
        if text.localizedCaseInsensitiveContains("No courses matched") {
            throw UniversityServiceError.message("No sections match this department, course number and term.")
        }
        guard text.range(of: #"(?m)^\s*\*\*\* Total Classes Displayed:\s*[1-9][0-9]*\b"#, options: .regularExpression) != nil else {
            throw UniversityServiceError.message("The Registrar did not return course sections. Check the term and department in WebSOC.")
        }
        return UniversityDocument(filename: "\(title).txt", data: Data(text.utf8), sourceURL: url())
    }
}
