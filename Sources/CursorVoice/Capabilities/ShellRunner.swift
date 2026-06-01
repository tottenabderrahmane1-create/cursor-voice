import Foundation

enum ShellRunner {
    static func run(_ command: String) async -> [String: String] {
        if isDestructive(command) {
            return ["error": "refused: command looks destructive"]
        }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", command]
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    cont.resume(returning: ["error": error.localizedDescription])
                    return
                }
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                var out = String(data: data, encoding: .utf8) ?? ""
                if out.count > 4000 { out = String(out.prefix(4000)) + "\n…(truncated)" }
                cont.resume(returning: [
                    "exit": String(process.terminationStatus),
                    "output": out
                ])
            }
        }
    }

    private static func isDestructive(_ cmd: String) -> Bool {
        let lower = cmd.lowercased()
        let banned = ["rm -rf", "sudo ", "mkfs", "dd if=", "shutdown", "halt", ":(){:|:&};:", "diskutil erase"]
        return banned.contains(where: lower.contains)
    }
}
