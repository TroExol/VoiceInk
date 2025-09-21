import Foundation
import SwiftUI
import AppKit

struct EmailSupport {
    static func generateSupportEmailURL() -> URL? {
        let subject = String(localized: "support.email.subject")
        let systemInfo = String(
            format: String(localized: "support.email.systemInfo"),
            locale: Locale.current,
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
            ProcessInfo.processInfo.operatingSystemVersionString,
            getMacModel(),
            getCPUInfo(),
            getMemoryInfo()
        )

        let body = String(
            format: String(localized: "support.email.body"),
            locale: Locale.current,
            systemInfo
        )
        
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        
        return URL(string: "mailto:prakashjoshipax@gmail.com?subject=\(encodedSubject)&body=\(encodedBody)")
    }
    
    static func openSupportEmail() {
        if let emailURL = generateSupportEmailURL() {
            NSWorkspace.shared.open(emailURL)
        }
    }
    
    private static func getMacModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &machine, &size, nil, 0)
        return String(cString: machine)
    }
    
    private static func getCPUInfo() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
    
    private static func getMemoryInfo() -> String {
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        return ByteCountFormatter.string(fromByteCount: Int64(totalMemory), countStyle: .memory)
    }
    
} 