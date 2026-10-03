import SwiftUI

// AppMode — lets the dev iPhone run the CLEAN product experience without an App
// Store Release build (C3.5 §6). Two modes:
//   .product : real dev backend + real C1–C3 AI, NO debug panels/diagnostics.
//   .aiDebug : diagnostics visible (SceneUnderstanding, beats/shots, decision,
//              model/latency, Good/Bad feedback).
//
// Resolution order (DEBUG builds only; a Release build is ALWAYS .product):
//   1) launch argument  -STORY_MODE product | -STORY_MODE aidebug
//   2) UserDefaults key  story_mode = "product" | "aidebug"
//   3) default           .product   (so acceptance runs are clean by default)
//
// Diagnostics must gate on `AppMode.current.showsDiagnostics`, NOT bare #if DEBUG,
// so the product experience is inspectable from Xcode.
enum AppMode: String {
    case product
    case aiDebug

    static var current: AppMode {
        #if DEBUG
        if let arg = argMode() { return arg }
        if let s = UserDefaults.standard.string(forKey: "story_mode"),
           let m = AppMode(fromToken: s) { return m }
        return .product
        #else
        return .product
        #endif
    }

    var showsDiagnostics: Bool { self == .aiDebug }

    private init?(fromToken t: String) {
        switch t.lowercased() {
        case "product", "presentation": self = .product
        case "aidebug", "debug", "ai_debug": self = .aiDebug
        default: return nil
        }
    }

    private static func argMode() -> AppMode? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-STORY_MODE"), i + 1 < args.count else { return nil }
        return AppMode(fromToken: args[i + 1])
    }
}
