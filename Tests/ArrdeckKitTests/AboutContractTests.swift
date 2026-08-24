import Foundation
import Testing
@testable import ArrdeckKit

/// The Feature enum's raw values are a contract with the backend's
/// FEATURE_ROUTES table. The backend repo is pinned as a submodule, so instead
/// of trusting the two lists to stay aligned, read the pinned source and fail
/// when they drift — the same move the backend itself uses to keep /about
/// honest against its router.
struct AboutContractTests {
    /// Walks up from this test file to the repo root, where the submodule lives.
    /// #filePath is the only stable anchor under `swift test`, which runs from
    /// a build directory rather than the package root.
    func backendFeatureNames() throws -> Set<String> {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        let about = dir.appending(path: "arrdeck/backend/app/api/v1/about.py")
        let source = try String(contentsOf: about, encoding: .utf8)

        // The closing brace is matched at line start on purpose: the route
        // *values* contain braces ("/api/v1/diagnose/{app}/{item_id}"), so the
        // first "}" after the opener is inside the first path, not the dict end.
        guard let start = source.range(of: "FEATURE_ROUTES"),
              let open = source.range(of: "{", range: start.upperBound..<source.endIndex),
              let close = source.range(of: "\n}", range: open.upperBound..<source.endIndex)
        else {
            Issue.record("FEATURE_ROUTES not found — the backend layout changed")
            return []
        }
        let body = source[open.upperBound..<close.lowerBound]
        // Keys are the quoted string opening each line.
        let names = body.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"") else { return nil }
            let inner = trimmed.dropFirst()
            guard let end = inner.firstIndex(of: "\"") else { return nil }
            return String(inner[..<end])
        }
        return Set(names)
    }

    @Test func everyBackendFeatureHasAnEnumCase() throws {
        let backend = try backendFeatureNames()
        #expect(!backend.isEmpty)
        let known = Set(Feature.allCases.map(\.rawValue))
        let missing = backend.subtracting(known)
        #expect(missing.isEmpty, "backend features with no Feature case: \(missing.sorted())")
    }

    @Test func noEnumCaseNamesAFeatureTheBackendDoesNotHave() throws {
        let backend = try backendFeatureNames()
        let phantom = Set(Feature.allCases.map(\.rawValue)).subtracting(backend)
        #expect(phantom.isEmpty, "Feature cases the pinned backend lacks: \(phantom.sorted())")
    }
}
