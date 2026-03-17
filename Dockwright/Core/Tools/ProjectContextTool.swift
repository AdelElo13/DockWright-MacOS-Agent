import Foundation
import os

/// Git and project structure awareness tool.
/// Provides git operations, directory tree, file search, and project type detection.
nonisolated struct ProjectContextTool: Tool, @unchecked Sendable {
    let name = "project_context"
    let description = """
        Git and project structure operations. IMPORTANT: Use the home directory from the system context for paths — never guess usernames or paths. Actions:
        - git_status: Show git status for a directory
        - git_log: Show recent commits (count param, default 10)
        - git_diff: Show diff (staged param: true for staged, false for unstaged, default unstaged)
        - git_branch: List, create, or switch branches (sub_action: list/create/switch, branch_name)
        - project_structure: Show directory tree (depth param, default 3)
        - find_files: Find files matching a glob pattern
        - read_file: Read a file's contents
        - detect_project: Detect project type and return info
        """

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "Action: git_status, git_log, git_diff, git_branch, project_structure, find_files, read_file, detect_project",
            "enum": ["git_status", "git_log", "git_diff", "git_branch", "project_structure", "find_files", "read_file", "detect_project"]
        ] as [String: Any],
        "path": [
            "type": "string",
            "description": "Working directory or file path"
        ] as [String: Any],
        "count": [
            "type": "integer",
            "description": "Number of commits for git_log (default 10)",
            "optional": true
        ] as [String: Any],
        "staged": [
            "type": "boolean",
            "description": "If true, show staged diff; if false, unstaged (default false)",
            "optional": true
        ] as [String: Any],
        "depth": [
            "type": "integer",
            "description": "Directory tree depth for project_structure (default 3)",
            "optional": true
        ] as [String: Any],
        "pattern": [
            "type": "string",
            "description": "Glob pattern for find_files (e.g. '*.swift')",
            "optional": true
        ] as [String: Any],
        "sub_action": [
            "type": "string",
            "description": "Sub-action for git_branch: list, create, switch",
            "optional": true
        ] as [String: Any],
        "branch_name": [
            "type": "string",
            "description": "Branch name for git_branch create/switch",
            "optional": true
        ] as [String: Any]
    ]

    private static let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "ProjectContextTool")

    /// Directories excluded from project_structure and find_files.
    private static let excludedDirs: Set<String> = [
        "node_modules", ".git", "build", "Build", "DerivedData",
        ".build", "Pods", ".svn", ".hg", "dist", ".next",
        "__pycache__", ".venv", "venv", ".tox", "target",
        ".gradle", ".idea", ".vs", "bin", "obj", ".cache"
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Missing required parameter: action", isError: true)
        }
        guard let path = arguments["path"] as? String else {
            return ToolResult("Missing required parameter: path", isError: true)
        }

        let expandedPath = (path as NSString).expandingTildeInPath

        switch action {
        case "git_status":
            return await runGit(["status", "--porcelain=v1", "-b"], in: expandedPath)

        case "git_log":
            let count = arguments["count"] as? Int ?? 10
            let clampedCount = min(max(count, 1), 100)
            return await runGit(
                ["log", "--oneline", "--decorate", "-n", "\(clampedCount)"],
                in: expandedPath
            )

        case "git_diff":
            let staged = arguments["staged"] as? Bool ?? false
            var args = ["diff"]
            if staged { args.append("--cached") }
            return await runGit(args, in: expandedPath)

        case "git_branch":
            return await handleGitBranch(arguments: arguments, workingDir: expandedPath)

        case "project_structure":
            let depth = arguments["depth"] as? Int ?? 3
            let clampedDepth = min(max(depth, 1), 10)
            return buildDirectoryTree(at: expandedPath, maxDepth: clampedDepth)

        case "find_files":
            guard let pattern = arguments["pattern"] as? String, !pattern.isEmpty else {
                return ToolResult("Missing required parameter: pattern for find_files", isError: true)
            }
            return findFiles(in: expandedPath, pattern: pattern)

        case "read_file":
            return readFile(at: expandedPath)

        case "detect_project":
            return detectProject(at: expandedPath)

        default:
            return ToolResult("Unknown action: \(action)", isError: true)
        }
    }

    // MARK: - Git Helpers

    private func handleGitBranch(arguments: [String: Any], workingDir: String) async -> ToolResult {
        let subAction = arguments["sub_action"] as? String ?? "list"

        switch subAction {
        case "list":
            return await runGit(["branch", "-a", "--no-color"], in: workingDir)

        case "create":
            guard let branchName = arguments["branch_name"] as? String, !branchName.isEmpty else {
                return ToolResult("Missing branch_name for git_branch create", isError: true)
            }
            return await runGit(["checkout", "-b", branchName], in: workingDir)

        case "switch":
            guard let branchName = arguments["branch_name"] as? String, !branchName.isEmpty else {
                return ToolResult("Missing branch_name for git_branch switch", isError: true)
            }
            return await runGit(["checkout", branchName], in: workingDir)

        default:
            return ToolResult("Unknown sub_action: \(subAction). Use: list, create, switch", isError: true)
        }
    }

    private func runGit(_ args: [String], in workingDir: String) async -> ToolResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: workingDir, isDirectory: &isDir), isDir.boolValue else {
            return ToolResult("Directory does not exist: \(workingDir)", isError: true)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: workingDir)

                // Prevent git from prompting for credentials
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                process.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ToolResult(
                        "Failed to run git: \(error.localizedDescription)", isError: true
                    ))
                    return
                }

                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdout = String(data: stdoutData.prefix(100_000), encoding: .utf8) ?? ""
                let stderr = String(data: stderrData.prefix(10_000), encoding: .utf8) ?? ""
                let exitCode = process.terminationStatus

                if exitCode != 0 {
                    let msg = stderr.isEmpty ? "git exited with code \(exitCode)" : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: ToolResult(msg, isError: true))
                } else {
                    let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: ToolResult(output.isEmpty ? "(no output)" : output))
                }
            }
        }
    }

    // MARK: - Project Structure

    private func buildDirectoryTree(at rootPath: String, maxDepth: Int) -> ToolResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rootPath, isDirectory: &isDir), isDir.boolValue else {
            return ToolResult("Directory does not exist: \(rootPath)", isError: true)
        }

        let rootName = (rootPath as NSString).lastPathComponent
        var lines: [String] = [rootName + "/"]
        var count = 0
        let maxEntries = 500

        buildTree(path: rootPath, prefix: "", depth: 0, maxDepth: maxDepth,
                  lines: &lines, count: &count, maxEntries: maxEntries)

        if count >= maxEntries {
            lines.append("... (truncated at \(maxEntries) entries)")
        }

        return ToolResult(lines.joined(separator: "\n"))
    }

    private func buildTree(path: String, prefix: String, depth: Int, maxDepth: Int,
                           lines: inout [String], count: inout Int, maxEntries: Int) {
        guard depth < maxDepth, count < maxEntries else { return }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return }

        let filtered = entries
            .filter { !$0.hasPrefix(".") || $0 == ".env" || $0 == ".gitignore" }
            .filter { !Self.excludedDirs.contains($0) }
            .sorted()

        for (index, entry) in filtered.enumerated() {
            guard count < maxEntries else { return }
            count += 1

            let isLast = index == filtered.count - 1
            let connector = isLast ? "└── " : "├── "
            let childPrefix = isLast ? "    " : "│   "

            let fullPath = (path as NSString).appendingPathComponent(entry)
            var entryIsDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &entryIsDir)

            let suffix = entryIsDir.boolValue ? "/" : ""
            lines.append(prefix + connector + entry + suffix)

            if entryIsDir.boolValue {
                buildTree(path: fullPath, prefix: prefix + childPrefix,
                          depth: depth + 1, maxDepth: maxDepth,
                          lines: &lines, count: &count, maxEntries: maxEntries)
            }
        }
    }

    // MARK: - Find Files

    private func findFiles(in rootPath: String, pattern: String) -> ToolResult {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: rootPath) else {
            return ToolResult("Cannot search in: \(rootPath)", isError: true)
        }

        var matches: [String] = []
        let maxResults = 200

        while let file = enumerator.nextObject() as? String {
            if matches.count >= maxResults { break }

            // Skip excluded directories
            let components = file.components(separatedBy: "/")
            if components.contains(where: { Self.excludedDirs.contains($0) }) {
                continue
            }

            let filename = (file as NSString).lastPathComponent
            if matchesGlob(filename, pattern: pattern) {
                matches.append(file)
            }
        }

        if matches.isEmpty {
            return ToolResult("No files matching '\(pattern)' found in \(rootPath)")
        }

        var result = "Found \(matches.count) match(es):\n"
        result += matches.joined(separator: "\n")
        if matches.count >= maxResults {
            result += "\n[limited to \(maxResults) results]"
        }
        return ToolResult(result)
    }

    private func matchesGlob(_ string: String, pattern: String) -> Bool {
        let regexPattern = "^" + NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*\\*", with: ".*")
            .replacingOccurrences(of: "\\*", with: "[^/]*")
            .replacingOccurrences(of: "\\?", with: ".") + "$"
        return string.range(of: regexPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Read File

    private func readFile(at path: String) -> ToolResult {
        let fm = FileManager.default
        let resolved = (path as NSString).resolvingSymlinksInPath

        guard fm.fileExists(atPath: resolved) else {
            return ToolResult("File not found: \(path)", isError: true)
        }

        var isDir: ObjCBool = false
        fm.fileExists(atPath: resolved, isDirectory: &isDir)
        if isDir.boolValue {
            return ToolResult("Path is a directory, not a file. Use project_structure or find_files.", isError: true)
        }

        do {
            let attrs = try fm.attributesOfItem(atPath: resolved)
            guard let size = attrs[.size] as? UInt64 else {
                return ToolResult("Cannot read file attributes", isError: true)
            }

            let maxSize: UInt64 = 1_000_000
            if size > maxSize {
                return ToolResult("File too large (\(size) bytes, max \(maxSize)). Read a portion with the shell tool.", isError: true)
            }

            guard fm.isReadableFile(atPath: resolved) else {
                return ToolResult("Permission denied: cannot read \(path)", isError: true)
            }

            guard let data = fm.contents(atPath: resolved),
                  let content = String(data: data, encoding: .utf8) else {
                return ToolResult("Cannot read file (binary or encoding issue)", isError: true)
            }

            return ToolResult(content)
        } catch {
            return ToolResult("Cannot read file: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Detect Project

    /// Known project manifest files and their associated project types.
    private static let projectIndicators: [(file: String, type: String, ecosystem: String)] = [
        ("Package.swift", "Swift Package", "Swift"),
        ("*.xcodeproj", "Xcode Project", "Apple"),
        ("*.xcworkspace", "Xcode Workspace", "Apple"),
        ("package.json", "Node.js", "JavaScript"),
        ("Cargo.toml", "Rust Crate", "Rust"),
        ("go.mod", "Go Module", "Go"),
        ("pyproject.toml", "Python (pyproject)", "Python"),
        ("setup.py", "Python (setuptools)", "Python"),
        ("requirements.txt", "Python", "Python"),
        ("Pipfile", "Python (Pipenv)", "Python"),
        ("Gemfile", "Ruby", "Ruby"),
        ("pom.xml", "Maven (Java)", "Java"),
        ("build.gradle", "Gradle (Java/Kotlin)", "JVM"),
        ("build.gradle.kts", "Gradle Kotlin DSL", "JVM"),
        ("CMakeLists.txt", "CMake (C/C++)", "C/C++"),
        ("Makefile", "Make", "C/C++"),
        ("composer.json", "PHP (Composer)", "PHP"),
        ("pubspec.yaml", "Dart/Flutter", "Dart"),
        ("mix.exs", "Elixir (Mix)", "Elixir"),
        ("deno.json", "Deno", "JavaScript"),
        ("Dockerfile", "Docker", "Container"),
        ("docker-compose.yml", "Docker Compose", "Container"),
        ("docker-compose.yaml", "Docker Compose", "Container"),
        ("terraform.tf", "Terraform", "Infrastructure"),
    ]

    private func detectProject(at path: String) -> ToolResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return ToolResult("Directory does not exist: \(path)", isError: true)
        }

        guard let entries = try? fm.contentsOfDirectory(atPath: path) else {
            return ToolResult("Cannot list directory: \(path)", isError: true)
        }

        let entrySet = Set(entries)
        var detected: [(type: String, ecosystem: String, file: String)] = []

        for indicator in Self.projectIndicators {
            if indicator.file.contains("*") {
                // Glob match (e.g. *.xcodeproj)
                let suffix = indicator.file.replacingOccurrences(of: "*", with: "")
                if entries.contains(where: { $0.hasSuffix(suffix) }) {
                    let matched = entries.first(where: { $0.hasSuffix(suffix) }) ?? indicator.file
                    detected.append((indicator.type, indicator.ecosystem, matched))
                }
            } else if entrySet.contains(indicator.file) {
                detected.append((indicator.type, indicator.ecosystem, indicator.file))
            }
        }

        // Check for git
        let hasGit = entrySet.contains(".git")

        var lines: [String] = ["Project: \((path as NSString).lastPathComponent)"]
        lines.append("Path: \(path)")
        lines.append("Git: \(hasGit ? "yes" : "no")")

        if detected.isEmpty {
            lines.append("Type: unknown (no recognized project files)")
        } else {
            lines.append("Detected project types:")
            for d in detected {
                lines.append("  - \(d.type) (\(d.ecosystem)) — \(d.file)")
            }
        }

        // Count files by extension in the top level
        var extCounts: [String: Int] = [:]
        for entry in entries where !entry.hasPrefix(".") {
            let ext = (entry as NSString).pathExtension
            if !ext.isEmpty {
                extCounts[ext, default: 0] += 1
            }
        }
        if !extCounts.isEmpty {
            let sorted = extCounts.sorted { $0.value > $1.value }.prefix(10)
            lines.append("Top-level file extensions:")
            for (ext, count) in sorted {
                lines.append("  .\(ext): \(count)")
            }
        }

        return ToolResult(lines.joined(separator: "\n"))
    }
}
