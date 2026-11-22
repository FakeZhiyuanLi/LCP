import AppKit
import Foundation
import Security

/// Deliberately inspects only the known original recorder identities. Unsupported
/// third-party/renamed old binaries cannot be made safe by an advisory lease.
enum CaptureCompatibility {
    static let protocolVersion = 1
    static let leaseIdentifier = "org.lcp.capture.v1"

    static func check(configuration: CaptureConfiguration) throws {
        try check(
            installedBundles: configuration.legacyBundleURLs,
            processes: NSWorkspace.shared.runningApplications.compactMap { application in
                guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      application.bundleIdentifier == "dev.lcp.Recorder"
                        || application.executableURL?.lastPathComponent == "LCPRecorder" else { return nil }
                return ProcessIdentity(
                    processID: application.processIdentifier,
                    protocolMetadata: signedMetadata(processID: application.processIdentifier)
                )
            }
        )
    }

    static func check(installedBundles: [URL], processes: [ProcessIdentity]) throws {
        for url in installedBundles where FileManager.default.fileExists(atPath: url.path) {
            let plist = url.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plist),
                  let metadata = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  isCompatible(metadata) else {
                throw CaptureError.incompatibleRecorder("The installed LCP Recorder at \(url.path) predates the shared capture lease. Finish any recording and follow the capture migration guide before enabling desktop capture.")
            }
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
                  let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
                throw CaptureError.incompatibleRecorder("The installed LCP Recorder compatibility signature could not be verified. Rebuild and review the compatible recorder before capture.")
            }
        }
        for process in processes where !isCompatible(process.protocolMetadata) {
            throw CaptureError.incompatibleRecorder("A running LCP Recorder (PID \(process.processID)) does not declare the shared capture lease. Leave active recordings running; complete the idle migration before desktop capture.")
        }
    }

    struct ProcessIdentity {
        let processID: Int32
        /// From the running code's signed Info.plist, rather than its mutable
        /// installed path: replacing an app does not upgrade an old process.
        let protocolMetadata: [String: Any]?
    }

    private static func isCompatible(_ metadata: [String: Any]?) -> Bool {
        guard let version = metadata?["LCPCaptureProtocolVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.intValue == protocolVersion,
              version.doubleValue == Double(protocolVersion),
              metadata?["LCPCaptureLeaseIdentifier"] as? String == leaseIdentifier else { return false }
        return true
    }

    static func signedMetadata(processID: Int32) -> [String: Any]? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: processID)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoPList as String] as? [String: Any]
    }
}
