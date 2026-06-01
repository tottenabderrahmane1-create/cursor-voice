import Foundation

enum AppleScriptRunner {
    static func run(_ source: String) -> [String: String] {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return ["error": "could not parse AppleScript"]
        }
        let result = script.executeAndReturnError(&error)
        if let error = error {
            return ["error": (error["NSAppleScriptErrorMessage"] as? String) ?? "AppleScript error"]
        }
        return ["result": result.stringValue ?? ""]
    }
}
