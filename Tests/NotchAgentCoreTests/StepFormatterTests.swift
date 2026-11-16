// OWNER: workstream A (core-logic).
import Foundation
import Testing
import NotchAgentCore

private let repo = Fixture.repo

private func done(_ tool: String, _ input: JSONValue, cwd: String = repo) -> String {
    StepFormatter.completed(toolName: tool, toolInput: input, cwd: cwd)
}

private func now(_ tool: String, _ input: JSONValue, cwd: String = repo) -> String {
    StepFormatter.current(toolName: tool, toolInput: input, cwd: cwd)
}

private func label(_ tool: String, _ input: JSONValue, cwd: String = repo) -> String {
    StepFormatter.toolLabel(toolName: tool, toolInput: input, cwd: cwd)
}

@Suite struct StepFormatterCompletedTests {
    @Test func read() {
        #expect(done("Read", ["file_path": .string("\(repo)/src/auth/session.ts")]) == "Read `src/auth/session.ts`")
        #expect(done("Read", ["file_path": "/etc/hosts"]) == "Read `hosts`")
        #expect(done("Read", ["file_path": .string("\(repo)/src/../README.md")]) == "Read `README.md`")
    }

    @Test func bash() {
        #expect(done("Bash", ["command": "npm test -- src/auth"]) == "Ran `npm test -- src/auth`")
        let long = "npm run build -- --configuration production --verbose --stats-json"
        let text = done("Bash", ["command": .string(long)])
        #expect(text == "Ran `" + String(long.prefix(47)) + "…`")
    }

    @Test func bashCollapsesNewlinesAndNeverBreaksTheCodeSpan() {
        #expect(done("Bash", ["command": "cd src\n  ls"]) == "Ran `cd src ls`")
        #expect(!done("Bash", ["command": "echo `date`"]).dropFirst(5).dropLast().contains("`"))
    }

    @Test func edits() {
        #expect(done("Edit", ["file_path": .string("\(repo)/src/auth/session.ts")]) == "Edited `session.ts`")
        #expect(done("MultiEdit", ["file_path": .string("\(repo)/src/auth/session.ts")]) == "Edited `session.ts`")
        #expect(done("Write", ["file_path": .string("\(repo)/src/auth/session.ts")]) == "Wrote `session.ts`")
        #expect(done("NotebookEdit", ["notebook_path": .string("\(repo)/nb/a.ipynb")]) == "Edited `a.ipynb`")
    }

    @Test func searchesAndLists() {
        #expect(done("Grep", ["pattern": "SessionError"]) == "Searched “SessionError”")
        #expect(done("Glob", ["pattern": "**/*.ts"]) == "Listed `**/*.ts`")
        #expect(done("WebSearch", ["query": "swift testing traits"]) == "Searched the web for “swift testing traits”")
        #expect(done("WebFetch", ["url": "https://docs.example.com/auth/refresh", "prompt": "x"]) == "Fetched docs.example.com")
    }

    @Test func subagentsMcpAndOthers() {
        #expect(done("Task", ["description": "Find flaky tests", "prompt": "..."]) == "Ran a subagent: Find flaky tests")
        #expect(done("Agent", ["description": "Audit deps"]) == "Ran a subagent: Audit deps")
        #expect(done("mcp__github__create_issue", ["title": "x"]) == "Used create_issue (github)")
        #expect(done("Frobnicate", .null) == "Used Frobnicate")
    }

    @Test func fixtures() throws {
        for (name, expected) in [
            ("post-tool-use-read", "Read `src/auth/session.ts`"),
            ("post-tool-use-bash", "Ran `npm test -- src/auth`"),
            ("post-tool-use-edit", "Edited `session.ts`"),
            ("post-tool-use-grep", "Searched “SessionError”"),
        ] {
            let e = try Fixture.event(name)
            #expect(done(e.toolName ?? "", e.toolInput ?? .null, cwd: e.cwd) == expected, "\(name)")
        }
    }

    @Test func missingInputNeverCrashes() {
        for tool in ["Read", "Bash", "Edit", "Write", "Grep", "Glob", "WebFetch", "WebSearch", "Task", "LS"] {
            #expect(!done(tool, .null).isEmpty, "\(tool)")
            #expect(!now(tool, .null).isEmpty, "\(tool)")
            #expect(!label(tool, .null).isEmpty, "\(tool)")
        }
    }
}

@Suite struct StepFormatterCurrentTests {
    @Test func presentTense() {
        #expect(now("Read", ["file_path": .string("\(repo)/src/auth/session.ts")]) == "Reading session.ts")
        #expect(now("Edit", ["file_path": .string("\(repo)/src/auth/session.ts")]) == "Editing session.ts")
        #expect(now("MultiEdit", ["file_path": .string("\(repo)/src/auth/session.ts")]) == "Editing session.ts")
        #expect(now("Write", ["file_path": .string("\(repo)/src/auth/session.ts")]) == "Writing session.ts")
        #expect(now("Bash", ["command": "npm test -- src/auth"]) == "Running `npm test -- src/auth`")
        #expect(now("Grep", ["pattern": "SessionError"]) == "Searching “SessionError”")
        #expect(now("Glob", ["pattern": "**/*.ts"]) == "Listing `**/*.ts`")
        #expect(now("WebFetch", ["url": "https://docs.example.com/x"]) == "Fetching docs.example.com")
        #expect(now("WebSearch", ["query": "q"]) == "Searching the web for “q”")
        #expect(now("Task", ["description": "Find flaky tests"]) == "Running a subagent: Find flaky tests")
        #expect(now("mcp__linear__list_issues", .null) == "Using list_issues (linear)")
        #expect(now("Frobnicate", .null) == "Using Frobnicate")
    }

    @Test func preToolUseFixture() throws {
        let e = try Fixture.event("pre-tool-use-read")
        #expect(now(e.toolName ?? "", e.toolInput ?? .null, cwd: e.cwd) == "Reading session.ts")
    }
}

@Suite struct StepFormatterLabelTests {
    @Test func labels() {
        #expect(label("Read", ["file_path": .string("\(repo)/src/auth/session.ts")]) == "src/auth/session.ts")
        #expect(label("Edit", ["file_path": .string("\(repo)/src/auth/session.ts")]) == "src/auth/session.ts")
        #expect(label("Write", ["file_path": "/tmp/out.txt"]) == "out.txt")
        #expect(label("Bash", ["command": "npm test -- src/auth"]) == "npm test -- src/auth")
        #expect(label("Bash", ["command": .string(String(repeating: "a", count: 100))]).count == 48)
        #expect(label("Grep", ["pattern": "x"]) == "Grep")
        #expect(label("WebFetch", ["url": "https://a.b"]) == "WebFetch")
    }
}

@Suite struct PromptHeadlineTests {
    @Test func firstNonEmptyLineTrimmed() {
        #expect(StepFormatter.promptHeadline("add token refresh to auth") == "add token refresh to auth")
        #expect(StepFormatter.promptHeadline("\n\n   fix the build  \nand then the tests") == "fix the build")
    }

    @Test func cutToTheLimitWithAnEllipsis() {
        let p = String(repeating: "abc ", count: 40)
        let h = StepFormatter.promptHeadline(p)
        #expect(h.count == 60)
        #expect(h.hasSuffix("…"))
        #expect(StepFormatter.promptHeadline("hello world", limit: 5) == "hell…")
        #expect(StepFormatter.promptHeadline("hello", limit: 5) == "hello")
    }

    @Test func emptyPrompt() {
        #expect(StepFormatter.promptHeadline("") == "")
        #expect(StepFormatter.promptHeadline("  \n \n") == "")
    }
}
