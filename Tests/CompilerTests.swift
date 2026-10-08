import AppKit
import SwiftUI
import PDFKit

@main
struct CompilerTests {
    @MainActor
    static func main() async throws {
        testExecutablePriorityAndInvalidCustomDoNotSilentlyFallback()
        testPATHDiscoveryAndDeduplication()
        await testUnresponsiveExecutableIsStopped()
        testWatchParserSplitUTF8ANSIAndDiagnostics()
        testNativeRulerSharesEditorScrollViewAndUTF16LogicalLines()
        testIncrementalLineIndexMatchesFullRebuild()
        testUnicodeInsertionAndEndOfFileNavigation()
        testKeywordAndUnicodeHighlighting()
        testTokenizerCancellation()
        testMarkedTextDefersBindingAndCompile()
        testVisibleSyntaxUsesTemporaryDrawingAttributes()
        try testDocumentTabsPreserveBuffersAndSaveFailures()
        testDiagnosticsCannotOverwriteTyping()
        testTabEditorReuseAndIndependentUndo()
        try await testPreviewLatestRequestWins()
        try testFontConfigurationValidation()
        try await testRealCompileRelativeCrossFolderImportsAndExportFailurePreservesPDF()
        try await testWatchSuccessErrorRecoveryAndCleanup()
        try await testLowMemoryPreviewReleasesCompiler()
        try await testRapidPreviewRequestsKeepLatestRevision()
        try testLanguagePositionsEditsSnippetsAndFraming()
        try await testLanguageConnectionTimeoutCancellationAndCleanup()
        try await testRealTinymistAssistance()
        try await testFormattingUndoAndSave()
        try await testDelayedFormattingNeverOverwritesDraftOrDiscard()
        try await testHoverReadingAndMarkdown()
        testGitHunkDetailsAndPatch()
        try await testGitFileHistory()
        testGitStatusAndHunkParsing()
        try await testGitRepositoryAndDraftDecorations()
        try await testAutoSaveAndExternalChanges()
        try await testTerminationCancellationResumesAutoSave()
        print("PASS: 32 regression groups (compiler/editor/preview, tabs and undo, Git review, LSP assistance/formatting/hover reading, auto-save and external-change protection)")
    }

    @MainActor
    static func testHoverReadingAndMarkdown() async throws {
        let source = "# Heading\r\n\r\n**Bold** and `code` [link](https://example.com)\r\n- item\r\n```typst\r\n#let x = \"**literal**\"\r\n```\r\n> quote"
        let rendered = HoverMarkdown(source)
        expectEqual(rendered.blocks.map(\.kind), [.heading(1), .paragraph, .list, .code, .quote])
        expectTrue(rendered.blocks[1].inline.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        expectTrue(rendered.blocks[1].inline.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        expectTrue(rendered.blocks.allSatisfy { $0.inline.runs.allSatisfy { $0.link == nil } })
        expectEqual(rendered.blocks[3].text, "#let x = \"**literal**\"")
        expectEqual(HoverMarkdown("```\n**raw**").blocks.first?.kind, .code)
        expectEqual(HoverMarkdown("**plain**", markdown: false).blocks.first?.text, "**plain**")
        let limited = HoverMarkdown(String(repeating: "- **item**\n", count: 2000))
        expectTrue(limited.truncated); expectTrue(limited.blocks.count <= 120)
        expectEqual(LanguageCompletion.documentation(Array(repeating: String(repeating: "x", count: 10000), count: 100)).count, 10000)

        let editor = EditorView(text: .constant("#emph[hello]"), controller: EditorController(), onCommit: {}).makeSession()
        let popup = NSPopover(), token = UUID()
        editor.hoverPopover = popup; editor.hoverToken = token
        editor.deferHoverClose() // Leave the editor, cross the gap, then enter the popup.
        try await Task.sleep(for: .milliseconds(100))
        editor.hoverPointerChanged(true, token: token)
        try await Task.sleep(for: .milliseconds(450))
        expectTrue(editor.hoverPopover === popup)
        editor.hoverPointerChanged(false, token: UUID()) // Late callback from an old popup.
        expectNil(editor.hoverCloseTask)
        editor.hoverPointerChanged(false, token: token)
        try await Task.sleep(for: .milliseconds(450))
        expectNil(editor.hoverPopover); expectNil(editor.hoverCloseTask)
        editor.hoverPopover = NSPopover(); editor.deferHoverClose(); editor.detach()
        expectNil(editor.hoverPopover); expectNil(editor.hoverCloseTask)
        editor.hoverPopover = NSPopover()
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: editor.scrollView.contentView)
        expectNil(editor.hoverPopover)
        for _ in 0..<100 {
            weak var released: NSViewController?
            autoreleasepool {
                let popup = NSPopover()
                popup.contentViewController = NSHostingController(rootView: LanguageHoverView(document: rendered, pointerChanged: { _ in }))
                released = popup.contentViewController
                editor.hoverPopover = popup; editor.closeHover()
            }
            expectNil(released)
        }

        // Report parsing cost only; this does not measure full popup layout or app RSS.
        let sample = Array(repeating: source, count: 16).joined(separator: "\n\n")
        let start = Date()
        for _ in 0..<100 { autoreleasepool { _ = HoverMarkdown(sample) } }
        print(String(format: "Markdown parse: %.3f ms/document (%d UTF-8 bytes, 100 iterations)", Date().timeIntervalSince(start) * 10, sample.utf8.count))
    }

    static func testLanguagePositionsEditsSnippetsAndFraming() throws {
        let source = "中🙂\r\n#let x=1\r\n"
        let text = LSPText(source)
        expectEqual(text.position(5), ["line": 1, "character": 0])
        expectEqual(text.offset(["line": 0, "character": 3]), 3)
        expectNil(text.offset(["line": 0, "character": 2])) // Surrogate split
        expectNil(text.offset(["line": 0, "character": 4])) // CRLF is not part of the line
        func point(_ line: Int, _ column: Int) -> [String: Int] { ["line": line, "character": column] }
        let edits = try LanguageEdit.decode([
            ["range": ["start": point(1, 6), "end": point(1, 6)], "newText": " "],
            ["range": ["start": point(1, 7), "end": point(1, 7)], "newText": " "]
        ], source: source)
        expectEqual(LanguageEdit.applying(edits, to: source), "中🙂\r\n#let x = 1\r\n")
        expectThrows(try LanguageEdit.decode([
            ["range": ["start": point(1, 0), "end": point(1, 5)], "newText": ""],
            ["range": ["start": point(1, 3), "end": point(1, 6)], "newText": ""]
        ], source: source))
        let snippet = LanguageSnippet.expand("fn(${1:中🙂}, $1)$0")
        expectEqual(snippet.0, "fn(中🙂, 中🙂)")
        expectEqual(snippet.1, NSRange(location: 3, length: 3))
        let completions = LanguageCompletion.decode([["label": "answer", "insertTextFormat": 2,
            "textEdit": ["range": ["start": point(0, 1), "end": point(0, 4)], "newText": "answer(${1:value})$0"]]], source: "#ans", fallback: NSRange(location: 1, length: 3))
        expectEqual(completions.first?.edit.range, NSRange(location: 1, length: 3))
        expectEqual(completions.first?.edit.text, "answer(value)")
        expectEqual(LanguageCompletion.documentation(["kind": "markdown", "value": "文档🙂"]), "文档🙂")
        var framer = LSPFramer(), messages: [[String: Any]] = []
        let packet = try LSPFramer.encode(["jsonrpc": "2.0", "id": "1", "result": "中文🙂"])
        for byte in packet { messages += try framer.feed(Data([byte])) }
        expectEqual(messages.first?["result"] as? String, "中文🙂")
        expectEqual(try framer.feed(packet + packet).count, 2)
        var invalid = LSPFramer()
        expectThrows(try invalid.feed(Data("Content-Length: 99999999\r\n\r\n".utf8)))
    }

    static func testLanguageConnectionTimeoutCancellationAndCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit LSP timeout \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("server")
        try "#!/bin/sh\ntrap '' TERM\nwhile true; do sleep 1; done\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let client = try LSPConnection(executable: script.path, root: root, options: [:])
        let pid = client.processID
        do { _ = try await client.request("ignored", params: [:], timeout: 0.04); fatalError("Expected LSP timeout") }
        catch LanguageFailure.timeout { }
        let request = Task { try await client.request("cancelled", params: [:], timeout: 5) }
        try await Task.sleep(for: .milliseconds(20)); request.cancel()
        do { _ = try await request.value; fatalError("Expected request cancellation") } catch is CancellationError { }
        client.close()
        try await Task.sleep(for: .milliseconds(750))
        expectTrue(kill(pid, 0) != 0)
    }

    static func testRealTinymistAssistance() async throws {
        let executable = ["/opt/homebrew/bin/tinymist", "/usr/local/bin/tinymist"].first(where: FileManager.default.isExecutableFile(atPath:))
        guard let executable else { print("SKIP: real Tinymist not installed"); return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit real LSP \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("中 文.typ")
        try "disk version".write(to: file, atomically: true, encoding: .utf8)
        let service = TypstLanguageService()
        func document(_ source: String) -> LanguageDocument { LanguageDocument(file: file, root: root, source: source, executable: executable, fontArguments: []) }
        let completionSource = "#let answer = 42\n#ans"
        let response = try await service.request("textDocument/completion", document: document(completionSource), position: (completionSource as NSString).length)
        let completions = LanguageCompletion.decode(response, source: completionSource, fallback: NSRange(location: (completionSource as NSString).length - 3, length: 3))
        expectTrue(completions.contains { $0.label == "answer" })
        let hoverSource = "😀 #emph[hello]"
        let hover = try await service.request("textDocument/hover", document: document(hoverSource), position: 5)
        expectTrue(!LanguageCompletion.documentation((hover as? [String: Any])?["contents"]).isEmpty)
        let source = "#let x=1+2\n#x\n"
        let formatted = try await service.request("textDocument/formatting", document: document(source))
        let edits = try LanguageEdit.decode(formatted as! [[String: Any]], source: source)
        let new = LanguageEdit.applying(edits, to: source)
        expectTrue(new.contains("x = 1 + 2"))
        expectEqual(try String(contentsOf: file, encoding: .utf8), "disk version")
        await service.stop()
    }

    @MainActor
    static func testFormattingUndoAndSave() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tinymist") else { print("SKIP: native Tinymist formatting"); return }
        let language = LanguageSettings.shared
        let old = (language.enabled, language.customPath, language.formatOnSave)
        language.enabled = true; language.customPath = "/opt/homebrew/bin/tinymist"; language.formatOnSave = true
        defer { language.enabled = old.0; language.customPath = old.1; language.formatOnSave = old.2 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit format undo \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.typ"), source = "#let answer=1+2\n#answer\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let tab = DocumentTab(url: file, projectFolder: root, source: source)
        let editor = EditorView(text: .constant(source), controller: tab.controller, onCommit: {}, document: tab).makeSession()
        editor.synchronizeText()
        editor.textView.setSelectedRange(NSRange(location: 5, length: 6))
        try await tab.formatSource()
        expectEqual(editor.textView.selectedRange(), NSRange(location: 5, length: 6))
        let formatted = tab.source
        expectTrue(formatted.contains("answer = 1 + 2")); expectEqual(editor.textView.string, formatted)
        expectEqual(try String(contentsOf: file, encoding: .utf8), source)
        editor.documentUndoManager.undo(); expectEqual(tab.source, source)
        editor.documentUndoManager.redo(); expectEqual(tab.source, formatted)
        editor.documentUndoManager.undo()
        try await tab.savePrepared()
        expectEqual(try String(contentsOf: file, encoding: .utf8), formatted)
        expectFalse(tab.isDirty)
        editor.textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        do { try await tab.formatSource(); fatalError("Formatting touched IME composition") } catch is CancellationError { }
        editor.textView.insertText("", replacementRange: editor.textView.markedRange()); editor.commitCurrentText()
        language.customPath = "/does/not/exist/tinymist"
        tab.source += "// retained draft\n"; editor.synchronizeText()
        try await tab.savePrepared() // Failed formatter still saves the latest draft.
        expectEqual(try String(contentsOf: file, encoding: .utf8), tab.source)
        expectTrue(tab.controller.languageStatus.contains(L10n.text("original draft", "保存原稿")))
        tab.dispose()
        await TypstLanguageService.shared.stop()
    }

    @MainActor
    static func testDelayedFormattingNeverOverwritesDraftOrDiscard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit delayed format \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake-tinymist")
        let program = #"""
        #!/usr/bin/python3
        import json,sys,time,os
        with open(os.path.join(os.path.dirname(sys.argv[0]),'starts'), 'a') as log: log.write(str(os.getpid())+'\n')
        source=''
        while True:
            header={}
            while True:
                line=sys.stdin.buffer.readline()
                if not line: sys.exit(0)
                if line==b'\r\n': break
                k,v=line.decode().split(':',1);header[k.lower()]=v.strip()
            message=json.loads(sys.stdin.buffer.read(int(header['content-length'])))
            method=message.get('method')
            if method=='exit': break
            if method=='textDocument/didOpen': source=message['params']['textDocument']['text']
            if method=='textDocument/didChange': source=message['params']['contentChanges'][0]['text']
            if 'id' not in message: continue
            result=None
            if method=='initialize': result={'capabilities':{'positionEncoding':'utf-16'}}
            if method=='textDocument/formatting':
                time.sleep(.2)
                lines=source.split('\n')
                result=[{'range':{'start':{'line':0,'character':0},'end':{'line':len(lines)-1,'character':len(lines[-1])}},'newText':source.replace('x=1','x = 1')}]
            body=json.dumps({'jsonrpc':'2.0','id':message['id'],'result':result}).encode()
            sys.stdout.buffer.write(('Content-Length: %d\r\n\r\n'%len(body)).encode()+body);sys.stdout.buffer.flush()
        """#
        try program.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let service = TypstLanguageService()
        let context = LanguageDocument(file: root.appendingPathComponent("concurrency.typ"), root: root, source: "#let x=1\n", executable: script.path, fontArguments: [])
        _ = try await service.request("textDocument/hover", document: context, position: 5)
        await service.stop()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { _ = try await service.request("textDocument/hover", document: context, position: 5) } }
            try await group.waitForAll()
        }
        let starts = try String(contentsOf: root.appendingPathComponent("starts"), encoding: .utf8).split(separator: "\n")
        expectEqual(starts.count, 2) // One initial process and one shared replacement.
        await service.stop()
        try await Task.sleep(for: .milliseconds(750))
        for pid in starts { expectTrue(kill(Int32(pid)!, 0) != 0) }
        let language = LanguageSettings.shared, old = (language.enabled, language.customPath, language.formatOnSave)
        language.enabled = true; language.customPath = script.path; language.formatOnSave = true
        defer { language.enabled = old.0; language.customPath = old.1; language.formatOnSave = old.2 }
        func tab(_ name: String) throws -> DocumentTab {
            let file = root.appendingPathComponent(name + ".typ"), source = "#let x=1\n"
            try source.write(to: file, atomically: true, encoding: .utf8)
            return DocumentTab(url: file, projectFolder: root, source: source)
        }
        let concurrent = try tab("concurrent")
        let formatting = Task { try await concurrent.formatSource() }
        let saving = Task { try await concurrent.savePrepared() }
        try await formatting.value; try await saving.value
        expectEqual(concurrent.source, "#let x = 1\n")
        expectEqual(try String(contentsOf: concurrent.id, encoding: .utf8), concurrent.source)
        expectFalse(concurrent.isDirty)
        concurrent.dispose()
        let first = try tab("stale")
        let pending = Task { try await first.formatSource() }
        try await Task.sleep(for: .milliseconds(80)); first.source = "#let x=2\n"
        do { try await pending.value; fatalError("Stale formatting applied") } catch is CancellationError { }
        expectEqual(first.source, "#let x=2\n")
        expectEqual(try String(contentsOf: first.id, encoding: .utf8), "#let x=1\n")
        let discarded = try tab("discarded")
        let save = Task { try await discarded.savePrepared() }
        try await Task.sleep(for: .milliseconds(80)); discarded.dispose()
        do { try await save.value; fatalError("Discarded tab was saved") } catch is CancellationError { }
        expectEqual(try String(contentsOf: discarded.id, encoding: .utf8), "#let x=1\n")
        let auto = try tab("auto")
        auto.configureAutoSave(true); auto.source += "// new draft\n"; auto.scheduleAutoSave(delay: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(800))
        expectEqual(try String(contentsOf: auto.id, encoding: .utf8), "#let x = 1\n// new draft\n")
        expectFalse(auto.isDirty)
        let formattedAuto = try tab("formatted-auto")
        formattedAuto.configureAutoSave(true)
        try await formattedAuto.formatSource()
        try await Task.sleep(for: .milliseconds(1300))
        expectEqual(try String(contentsOf: formattedAuto.id, encoding: .utf8), "#let x = 1\n")
        expectFalse(formattedAuto.isDirty)
        first.dispose(); auto.dispose(); formattedAuto.dispose(); await TypstLanguageService.shared.stop()
    }

    @MainActor
    static func testGitHunkDetailsAndPatch() {
        let removal = GitHunk.parse("@@ -2,2 +1,0 @@")!
        expectTrue(removal.contains(line: 1, lineCount: 2))
        let preview = GitReader.hunkPreview(removal, before: "A\n删除前\nremoved\nZ\n", after: "A\nZ\n")
        expectEqual(preview.rows.map(\.text), ["删除前", "removed"])
        expectEqual(preview.rows.map(\.oldNumber), [2, 3])
        expectTrue(preview.rows.allSatisfy { $0.kind == .deleted && $0.newNumber == nil })
        let pair = GitReader.changedRanges("你好🙂 old 中文", "你好🙂 new 中文")
        expectEqual(pair.0, NSRange(location: 5, length: 3))
        expectEqual(pair.1, NSRange(location: 5, length: 3))
        let patch = GitReader.parsePatch("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n-old\n+new\n context\n\\ No newline at end of file\n")
        expectEqual(patch.rows.count, 4)
        expectEqual(patch.rows[1].oldNumber, 1); expectEqual(patch.rows[2].newNumber, 1)
        expectEqual(patch.rows[3].oldNumber, 2); expectEqual(patch.rows[3].newNumber, 2)
        expectEqual(patch.rows[1].emphasis, NSRange(location: 0, length: 3))
        let rendered = GitDiffTextView.attributed(patch.rows)
        expectTrue(rendered.string.contains("old")); expectTrue(rendered.string.contains("new"))
        let oldRange = (rendered.string as NSString).range(of: "old")
        expectTrue(rendered.attribute(.backgroundColor, at: oldRange.location, effectiveRange: nil) != nil)
        let huge = GitReader.hunkPreview(GitHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: 1000),
            before: "", after: String(repeating: "new\n", count: 1000))
        expectEqual(huge.rows.count, 200); expectTrue(huge.truncated)
        let hugePatch = GitReader.parsePatch("@@ -0,0 +1,2000 @@\n" + String(repeating: "+new\n", count: 2000))
        expectEqual(hugePatch.rows.count, 1000); expectTrue(hugePatch.truncated)
        expectNil(GitHunk.parse("@@ -x +1 @@"))
        let largeFile = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit output \(UUID())")
        defer { try? FileManager.default.removeItem(at: largeFile) }
        try! Data(repeating: 65, count: 256 * 1024).write(to: largeFile)
        let limited = CLIProcess.run(executable: "/bin/cat", arguments: [largeFile.path], directory: nil, maxOutputBytes: 128)
        expectEqual(limited.status, 0); expectEqual(limited.output.utf8.count, 128); expectTrue(limited.truncated)
    }

    static func testGitFileHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit history \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) -> String {
            let result = CLIProcess.run(executable: "/usr/bin/git", arguments: ["--literal-pathspecs"] + arguments, directory: root, timeout: 5)
            expectEqual(result.status, 0)
            return result.output.trimmingCharacters(in: .newlines)
        }
        _ = git(["init", "-q"])
        _ = git(["config", "user.name", "Regression"]); _ = git(["config", "user.email", "regression@example.invalid"])
        _ = git(["config", "commit.gpgsign", "false"])
        let original = root.appendingPathComponent("old\n中文.typ")
        try "before\nunchanged\n".write(to: original, atomically: true, encoding: .utf8)
        let reader = GitReader()
        let empty = await reader.history(root: root, file: original)
        expectTrue(empty.1.isEmpty); expectNil(empty.2)
        _ = git(["add", "--", original.lastPathComponent]); _ = git(["commit", "-qm", "Initial"])
        try "after\nunchanged\n".write(to: original, atomically: true, encoding: .utf8)
        _ = git(["add", "--", original.lastPathComponent]); _ = git(["commit", "-qm", "Modify 中文"])
        let renamed = root.appendingPathComponent(":(literal) new 中文.typ")
        _ = git(["mv", "--", original.lastPathComponent, renamed.lastPathComponent]); _ = git(["commit", "-qm", "Rename"])
        let statusBefore = git(["status", "--porcelain=v1", "-z"])
        let history = await reader.history(root: root, file: renamed)
        expectNil(history.2); expectEqual(history.1.count, 3)
        expectEqual(history.1.map(\.subject), ["Rename", "Modify 中文", "Initial"])
        expectEqual(history.1[0].status, "R100")
        expectEqual(history.1[0].path, renamed.lastPathComponent)
        expectEqual(history.1[0].oldPath, original.lastPathComponent)
        expectEqual(history.1[1].path, original.lastPathComponent)
        expectTrue(history.1[2].parents.isEmpty)
        let change = await reader.commitDiff(root: root, commit: history.1[1])
        expectTrue(change.rows.contains { $0.kind == .deleted && $0.text == "before" })
        expectTrue(change.rows.contains { $0.kind == .added && $0.text == "after" })
        let initial = await reader.commitDiff(root: root, commit: history.1[2])
        expectTrue(initial.rows.contains { $0.kind == .added && $0.text == "before" })
        let draft = await reader.currentHunk(root: root, file: renamed, source: "after\n", line: 1)
        expectTrue(draft.rows.contains { $0.kind == .deleted && $0.text == "unchanged" })
        expectEqual(try String(contentsOf: renamed, encoding: .utf8), "after\nunchanged\n")
        expectEqual(git(["status", "--porcelain=v1", "-z"]), statusBefore)
        let mainBranch = git(["branch", "--show-current"])
        _ = git(["checkout", "-qb", "feature"])
        try "branch version\nunchanged\n".write(to: renamed, atomically: true, encoding: .utf8)
        _ = git(["add", "--", renamed.lastPathComponent]); _ = git(["commit", "-qm", "Feature"])
        _ = git(["checkout", "-q", mainBranch])
        try "other".write(to: root.appendingPathComponent("other"), atomically: true, encoding: .utf8)
        _ = git(["add", "other"]); _ = git(["commit", "-qm", "Other file"])
        _ = git(["merge", "--no-ff", "-qm", "Merge feature", "feature"])
        let merged = await reader.history(root: root, file: renamed)
        expectEqual(merged.1.first?.subject, "Merge feature")
        expectEqual(merged.1.first?.parents.count, 2)
        expectFalse(merged.1.contains { $0.subject == "Feature" })
        let mergeDiff = await reader.commitDiff(root: root, commit: merged.1[0])
        expectTrue(mergeDiff.rows.contains { $0.kind == .added && $0.text == "branch version" })
        expectEqual(git(["status", "--porcelain=v1", "-z"]), statusBefore)
    }

    static func testGitStatusAndHunkParsing() {
        let (branch, changes) = GitSnapshot.parseStatus("## main...origin/main\0 M a.typ\0A  b.typ\0R  new name.typ\0old name.typ\0UU conflict.typ\0?? folder/\0?? odd\nname.typ\0?? .typstedit-preview-test.typ\0")
        expectEqual(branch, "main...origin/main")
        expectEqual(changes.count, 6)
        expectEqual(changes.first { $0.path == "new name.typ" }?.kind, .renamed)
        expectEqual(changes.first { $0.path == "new name.typ" }?.originalPath, "old name.typ")
        for status in ["UU", "AA", "DU", "UD", "AU", "UA", "DD"] {
            expectEqual(GitSnapshot.parseStatus(status + " conflict.typ\0").1.first?.kind, .conflicted)
        }
        expectTrue(GitSnapshot.parseStatus("R  truncated\0").1.isEmpty)
        expectEqual(GitReader.logicalLines("A\r\nB\u{2028}C\u{2029}D\r"), "A\nB\nC\nD\n")
        expectEqual(changes.first { $0.path == "conflict.typ" }?.kind, .conflicted)
        expectTrue(changes.first { $0.path == "b.typ" }!.staged)
        expectTrue(changes.first { $0.path == "a.typ" }!.unstaged)
        expectEqual(changes.first { $0.path == "odd\nname.typ" }?.kind, .untracked)
        let lines = GitSnapshot.parseHunks("@@ -1 +1,2 @@\n@@ -5,2 +6,0 @@\n@@ -8,0 +9,2 @@", lineCount: 10)
        expectEqual(lines[1], .modified); expectEqual(lines[2], .modified)
        expectEqual(lines[6], .deleted); expectEqual(lines[9], .added); expectEqual(lines[10], .added)
        expectEqual(GitSnapshot.parseHunks("@@ -1 +0,0 @@", lineCount: 1)[1], .deleted)
        let longAddition = GitSnapshot.parseHunks("@@ -0,0 +1,100000 @@", lineCount: 100000)
        expectEqual(longAddition.segments.count, 1)
        expectEqual(longAddition[100000], .added)
    }

    static func testGitRepositoryAndDraftDecorations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit git \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) {
            let result = CLIProcess.run(executable: "/usr/bin/git", arguments: arguments, directory: root, timeout: 5)
            expectEqual(result.status, 0)
        }
        git(["init", "-q"])
        let file = root.appendingPathComponent("中 文.typ")
        try "A\nB\nC\n".write(to: file, atomically: true, encoding: .utf8)
        let reader = GitReader()
        let unborn = await reader.snapshot(folder: root, file: file, source: "A\nB\nC\n")
        expectEqual(unborn.changes.first?.kind, .untracked)
        expectEqual(unborn.lines[1], .added)
        git(["add", "--", file.lastPathComponent])
        let stagedUnborn = await reader.snapshot(folder: root, file: file, source: "A\nB\nC\n")
        expectEqual(stagedUnborn.lines[1], .added)
        git(["config", "color.ui", "always"])
        git(["-c", "user.name=Regression", "-c", "user.email=regression@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"])
        let draft = await reader.snapshot(folder: root, file: file, source: "A\nchanged\nC\nnew\n")
        expectTrue(draft.changes.isEmpty) // Unsaved edits do not mutate the index/worktree.
        expectEqual(draft.lines[2], .modified); expectEqual(draft.lines[4], .added)
        expectEqual(try String(contentsOf: file, encoding: .utf8), "A\nB\nC\n")
        try "A\nchanged\nC\n".write(to: file, atomically: true, encoding: .utf8)
        let modified = await reader.snapshot(folder: root, file: file, source: "A\nchanged\nC\n")
        expectEqual(modified.changes.first?.kind, .modified)
        git(["add", "--", file.lastPathComponent])
        let staged = await reader.snapshot(folder: root, file: file, source: "A\nchanged\nC\n")
        expectTrue(staged.changes.first!.staged)
        expectEqual(staged.lines[2], .modified) // Compare with HEAD, including staged changes.
        let binary = await reader.snapshot(folder: root, file: file, source: "A\0B")
        expectTrue(binary.lines.isEmpty)
        let unicodeLines = await reader.snapshot(folder: root, file: file, source: "A\u{2028}different\u{2028}C\n")
        expectEqual(unicodeLines.lines[2], .modified)
        git(["restore", "--source=HEAD", "--staged", "--worktree", "--", file.lastPathComponent])
        git(["mv", "--", file.lastPathComponent, "renamed.typ"])
        let rename = await reader.snapshot(folder: root, file: root.appendingPathComponent("renamed.typ"), source: "A\nB\nC\n")
        expectEqual(rename.changes.first?.kind, .renamed)
        expectEqual(rename.changes.first?.originalPath, file.lastPathComponent)
        expectTrue(rename.lines.isEmpty)
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit no git \(UUID())")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        expectNil(await reader.snapshot(folder: plain, file: nil, source: nil).root)
        git(["worktree", "add", "--detach", root.appendingPathComponent("linked").path, "HEAD"])
        let linked = root.appendingPathComponent("linked")
        let worktree = await reader.snapshot(folder: linked, file: linked.appendingPathComponent(file.lastPathComponent), source: "draft\n")
        expectEqual(worktree.root, linked.resolvingSymlinksInPath())
        expectEqual(worktree.lines[1], .modified)
    }

    @MainActor
    static func testAutoSaveAndExternalChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit auto \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func tab(_ name: String) throws -> DocumentTab {
            let file = root.appendingPathComponent(name + ".typ")
            try "saved".write(to: file, atomically: true, encoding: .utf8)
            return DocumentTab(url: file, projectFolder: root, source: "saved")
        }
        let a = try tab("a"), b = try tab("b")
        a.configureAutoSave(true); b.configureAutoSave(true)
        a.source = "stale"; a.scheduleAutoSave(delay: .milliseconds(30))
        a.source = "latest"; a.scheduleAutoSave(delay: .milliseconds(50))
        b.source = "B"; b.scheduleAutoSave(delay: .milliseconds(30))
        try await Task.sleep(for: .milliseconds(120))
        expectEqual(try String(contentsOf: a.id, encoding: .utf8), "latest")
        expectEqual(try String(contentsOf: b.id, encoding: .utf8), "B")
        expectFalse(a.isDirty); expectFalse(b.isDirty)
        a.source = "suspended"; a.scheduleAutoSave(delay: .milliseconds(30)); a.suspendAutoSave(true)
        try await Task.sleep(for: .milliseconds(70))
        expectEqual(try String(contentsOf: a.id, encoding: .utf8), "latest")
        a.suspendAutoSave(false); a.scheduleAutoSave(delay: .milliseconds(30))
        try await Task.sleep(for: .milliseconds(70))
        expectEqual(try String(contentsOf: a.id, encoding: .utf8), "suspended")
        a.source = "discarded"; a.scheduleAutoSave(delay: .milliseconds(30)); a.dispose()
        try await Task.sleep(for: .milliseconds(70))
        expectEqual(try String(contentsOf: a.id, encoding: .utf8), "suspended")
        try "external".write(to: b.id, atomically: true, encoding: .utf8)
        b.source = "draft"; b.scheduleAutoSave(delay: .milliseconds(30))
        try await Task.sleep(for: .milliseconds(70))
        expectTrue(b.isDirty); expectTrue(b.autoSaveError != nil)
        expectEqual(try String(contentsOf: b.id, encoding: .utf8), "external")
        expectThrows(try b.save())
        b.dispose()
        let c = try tab("ime")
        let session = EditorView(text: .constant(c.source), controller: c.controller, onCommit: {}, document: c).makeSession()
        session.synchronizeText(); c.configureAutoSave(true)
        c.source = "committed draft"; c.scheduleAutoSave(delay: .milliseconds(30))
        session.textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 5, length: 0))
        try await Task.sleep(for: .milliseconds(70))
        expectEqual(try String(contentsOf: c.id, encoding: .utf8), "saved")
        session.textView.insertText("你", replacementRange: session.textView.markedRange())
        session.commitCurrentText(); c.scheduleAutoSave(delay: .milliseconds(30))
        try await Task.sleep(for: .milliseconds(70))
        expectEqual(try String(contentsOf: c.id, encoding: .utf8), c.source)
        c.source += " draft"
        session.synchronizeText()
        let end = session.textView.string.utf16.count
        session.textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: end, length: 0))
        c.scheduleAutoSave(delay: .milliseconds(30))
        try await Task.sleep(for: .milliseconds(70))
        session.textView.insertText("", replacementRange: session.textView.markedRange())
        session.commitCurrentText()
        try await Task.sleep(for: .milliseconds(1100))
        expectEqual(try String(contentsOf: c.id, encoding: .utf8), c.source)
        c.dispose()
    }

    @MainActor
    static func testTerminationCancellationResumesAutoSave() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit quit \(UUID()).typ")
        try "saved".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let tab = DocumentTab(url: file, projectFolder: file.deletingLastPathComponent(), source: "saved")
        tab.configureAutoSave(true); tab.suspendAutoSave(true); tab.source = "retained draft"
        let checks = ApplicationDelegate.closeChecks, resumes = ApplicationDelegate.closeCancellations
        defer { ApplicationDelegate.closeChecks = checks; ApplicationDelegate.closeCancellations = resumes; tab.dispose() }
        ApplicationDelegate.closeChecks = [UUID(): { false }]
        ApplicationDelegate.closeCancellations = [UUID(): { tab.suspendAutoSave(false) }]
        expectEqual(ApplicationDelegate().applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        tab.scheduleAutoSave(delay: .milliseconds(30))
        try await Task.sleep(for: .milliseconds(70))
        expectEqual(try String(contentsOf: file, encoding: .utf8), "retained draft")
    }

    static func testExecutablePriorityAndInvalidCustomDoNotSilentlyFallback() {
        let valid = Set(["/system/typst", "/bundle/typst", "/with spaces/typst"])
        let executable: (String) -> Bool = { valid.contains($0) }
        expectEqual(TypstExecutableResolver.resolve(choice: .automatic, customPath: "", bundledPath: "/bundle/typst", systemPaths: ["/missing", "/system/typst"], isExecutable: executable), "/system/typst")
        expectEqual(TypstExecutableResolver.resolve(choice: .automatic, customPath: "", bundledPath: "/bundle/typst", systemPaths: [], isExecutable: executable), "/bundle/typst")
        expectEqual(TypstExecutableResolver.resolve(choice: .custom, customPath: "/with spaces/typst", bundledPath: "/bundle/typst", isExecutable: executable), "/with spaces/typst")
        expectNil(TypstExecutableResolver.resolve(choice: .custom, customPath: "/missing", bundledPath: "/bundle/typst", isExecutable: executable))
        expectNil(TypstExecutableResolver.resolve(choice: .custom, customPath: "relative", bundledPath: "/bundle/typst", isExecutable: executable))
        expectEqual(TypstExecutableResolver.resolve(choice: .bundled, customPath: "", bundledPath: "/bundle/typst", systemPaths: ["/system/typst"], isExecutable: executable), "/bundle/typst")
    }

    static func testPATHDiscoveryAndDeduplication() {
        let paths = TypstExecutableResolver.candidates(environment: ["PATH": "/custom/bin:/opt/homebrew/bin:/custom/bin"], home: "/test")
        expectEqual(paths.first, "/custom/bin/typst")
        expectEqual(paths.filter { $0 == "/custom/bin/typst" }.count, 1)
        expectTrue(paths.contains("/test/.cargo/bin/typst"))
    }

    static func testUnresponsiveExecutableIsStopped() async {
        let start = ContinuousClock.now
        let result = await Task.detached {
            CLIProcess.run(executable: "/usr/bin/python3", arguments: ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready',flush=True); time.sleep(10)"], directory: nil, timeout: 0.5)
        }.value
        expectTrue(result.output.contains("ready"))
        expectTrue(result.status != 0)
        expectTrue(start.duration(to: .now) < .seconds(3))
    }

    static func testWatchParserSplitUTF8ANSIAndDiagnostics() {
        var parser = WatchOutputParser()
        let data = Data("\u{001B}[31m/tmp/中文.typ:12:4: error: 中文错误\u{001B}[0m\ncompiled with errors\n".utf8)
        var lines: [String] = []
        for byte in data { lines += parser.append(Data([byte])) }
        expectEqual(lines.count, 2)
        let error = WatchOutputParser.diagnostic(lines[0])
        expectEqual(error?.line, 12)
        expectEqual(error?.message, "中文错误")
        expectEqual(error?.filePath, "/tmp/中文.typ")
        expectNil(WatchOutputParser.diagnostic(lines[1]))
        expectNil(WatchOutputParser.diagnostic("/tmp/main.typ:2:1: warning: test"))
        expectEqual(WatchOutputParser.diagnostic("error: fonts unavailable")?.line, 0)
    }

    @MainActor
    static func testNativeRulerSharesEditorScrollViewAndUTF16LogicalLines() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 2000))
        scroll.documentView = text
        let ruler = LineNumberRulerView(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = text
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        ruler.updateLineStarts("中😀\r\nsecond\n\n")
        expectEqual(ruler.lineStarts, [0, 5, 12, 13])
        expectTrue(ruler.scrollView === scroll)
        expectTrue(ruler.clientView === text)
        ruler.updateLineStarts("")
        expectEqual(ruler.lineStarts, [0])
    }

    @MainActor
    static func testUnicodeInsertionAndEndOfFileNavigation() {
        let view = NSTextView()
        view.string = "中文😀\n"
        let controller = EditorController()
        controller.textView = view
        controller.goToLine(999)
        expectEqual(view.selectedRange().location, view.string.utf16.count)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        controller.wrapSelection(prefix: "😀", suffix: "中")
        expectEqual(view.selectedRange().location, 2)
        controller.searchQuery = "中文"
        let caret = NSRange(location: view.string.utf16.count, length: 0)
        view.setSelectedRange(caret)
        controller.refreshSearch()
        expectEqual(view.selectedRange(), caret)
    }

    static func testKeywordAndUnicodeHighlighting() {
        let source = "#let 中文 = \"😀\"\n= 标题\n// 注释"
        let spans = SyntaxHighlighter.spans(in: source)
        let string = source as NSString
        expectTrue(spans.contains { $0.style == 0 && string.substring(with: $0.range) == "let" })
        expectTrue(spans.contains { $0.style == 4 && string.substring(with: $0.range) == "= 标题" })
        expectTrue(spans.contains { $0.style == 5 && string.substring(with: $0.range) == "// 注释" })
    }

    @MainActor
    static func testIncrementalLineIndexMatchesFullRebuild() {
        let incremental = LineNumberRulerView(scrollView: nil, orientation: .verticalRuler)
        let reference = LineNumberRulerView(scrollView: nil, orientation: .verticalRuler)
        var binding = ""
        let editor = EditorView(text: Binding(get: { binding }, set: { binding = $0 }), controller: EditorController(), onCommit: {})
        let coordinator = EditorView.Session(editor)
        var source = "中😀\r\nsecond\n\nend\r"
        incremental.updateLineStarts(source)
        coordinator.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: source)
        var seed: UInt64 = 871
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int((seed >> 32) % UInt64(bound))
        }
        let replacements = ["", "\n", "\r", "\r\n", "中文😀", "x", "\u{2028}", "\u{2029}"]
        for _ in 0..<3_000 {
            var boundaries = [0]
            var offset = 0
            for scalar in source.unicodeScalars {
                offset += scalar.value > 0xffff ? 2 : 1
                boundaries.append(offset)
            }
            let first = next(boundaries.count)
            let last = first + next(boundaries.count - first)
            let range = NSRange(location: boundaries[first], length: boundaries[last] - boundaries[first])
            let replacement = replacements[next(replacements.count)]
            source = (source as NSString).replacingCharacters(in: range, with: replacement)
            coordinator.textStorage.replaceCharacters(in: range, with: replacement)
            incremental.applyEdit(in: source as NSString, editedRange: NSRange(location: range.location, length: replacement.utf16.count), changeInLength: replacement.utf16.count - range.length)
            reference.updateLineStarts(source)
            expectEqual(incremental.lineStarts, reference.lineStarts)
            expectEqual(coordinator.ruler.lineStarts, reference.lineStarts)
        }
    }

    static func testTokenizerCancellation() {
        let source = String(repeating: "#let x = \"中文😀\" // comment\n", count: 10_000)
        var checks = 0
        let cancelled = SyntaxHighlighter.spans(in: source, isCancelled: { checks += 1; return checks > 100 })
        expectTrue(cancelled.isEmpty)
        expectTrue(checks <= 110)
    }

    @MainActor
    static func testDocumentTabsPreserveBuffersAndSaveFailures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit tabs \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let aURL = root.appendingPathComponent("a.typ"), bURL = root.appendingPathComponent("b.typ")
        try "A saved".write(to: aURL, atomically: true, encoding: .utf8)
        try "B saved".write(to: bURL, atomically: true, encoding: .utf8)
        let workspace = DocumentWorkspace()
        let a = try workspace.open(aURL, projectFolder: root)
        workspace.activate(a)
        a.source = "A unsaved"
        let b = try workspace.open(bURL, projectFolder: root)
        workspace.activate(b)
        expectTrue(workspace.isDirty)
        expectEqual(try String(contentsOf: aURL, encoding: .utf8), "A saved")
        workspace.activate(a)
        expectEqual(workspace.active?.source, "A unsaved")
        let link = root.appendingPathComponent("alias.typ")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: aURL)
        expectTrue(try workspace.open(link, projectFolder: root) === a)
        expectEqual(workspace.tabs.count, 2)
        try a.save()
        expectFalse(a.isDirty)
        expectEqual(try String(contentsOf: aURL, encoding: .utf8), "A unsaved")
        b.source = "B unsaved"
        try FileManager.default.removeItem(at: bURL)
        try FileManager.default.createDirectory(at: bURL, withIntermediateDirectories: true)
        expectThrows(try b.save())
        expectTrue(b.isDirty)
        expectEqual(b.savedSource, "B saved")
        expectEqual(workspace.tabs.count, 2)
        workspace.close(a)
        expectTrue(workspace.active === b)
        workspace.closeAll()
        expectTrue(workspace.tabs.isEmpty)
        expectNil(workspace.active)
    }

    @MainActor
    static func testDiagnosticsCannotOverwriteTyping() {
        let tab = DocumentTab(url: URL(fileURLWithPath: "/tmp/errors.typ"), projectFolder: URL(fileURLWithPath: "/tmp"),
                              source: "#let title = \"broken\n#title\n")
        // Deliberately stale Binding models a delayed SwiftUI repaint during diagnostics.
        let editor = EditorView(text: .constant("old snapshot"), controller: tab.controller, onCommit: {}, document: tab)
        let coordinator = editor.makeSession()
        coordinator.synchronizeText()
        let view = coordinator.textView
        tab.controller.textView = view
        tab.controller.errors = [TypstError(line: 1, message: "unclosed string")]
        expectEqual(coordinator.ruler.errors, Set([1]))
        tab.controller.errors = []
        expectTrue(coordinator.ruler.errors.isEmpty)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        let observation = tab.objectWillChange.sink { coordinator.synchronizeText() }
        var expected = tab.source
        for character in "abcdef中文😀" {
            tab.controller.errors = [TypstError(line: 1, message: "unclosed delimiter")]
            coordinator.synchronizeText()
            let text = String(character)
            view.insertText(text, replacementRange: view.selectedRange())
            // Force a diagnostic redraw before AppKit delivers textDidChange.
            tab.controller.errors = [TypstError(line: 2, message: "expected comma")]
            coordinator.synchronizeText()
            expectEqual(view.string, expected + text)
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
            expected += text
            coordinator.synchronizeText()
            expectEqual(tab.source, expected)
            expectEqual(view.string, expected)
            expectEqual(view.selectedRange().location, expected.utf16.count)
            expectTrue(view.isEditable)
        }
        let end = expected.utf16.count
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: end, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        coordinator.synchronizeText()
        expectEqual(tab.source, expected)
        view.insertText("你", replacementRange: view.markedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        expectEqual(tab.source, expected + "你")
        observation.cancel()
        tab.dispose()
    }

    @MainActor
    static func testTabEditorReuseAndIndependentUndo() {
        func make(_ name: String) -> DocumentTab {
            DocumentTab(url: URL(fileURLWithPath: "/tmp/\(name).typ"), projectFolder: URL(fileURLWithPath: "/tmp"), source: name)
        }
        let a = make("A"), b = make("B")
        func editor(_ tab: DocumentTab) -> EditorView {
            EditorView(text: .constant("stale"), controller: tab.controller, onCommit: {}, document: tab)
        }
        let aCoordinator = editor(a).makeSession(), bCoordinator = editor(b).makeSession()
        for (tab, coordinator) in [(a, aCoordinator), (b, bCoordinator)] {
            coordinator.synchronizeText()
            let view = coordinator.textView
            coordinator.highlighter.install(SyntaxHighlighter.spans(in: view.string), in: view)
            view.setSelectedRange(NSRange(location: 1, length: 0))
            expectTrue(view.undoManager === coordinator.documentUndoManager)
            let undo = view.undoManager!
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            view.insertText("!", replacementRange: view.selectedRange())
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
            undo.endUndoGrouping()
            expectEqual(tab.source, tab.url.deletingPathExtension().lastPathComponent + "!")
        }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let bridge = EditorView.Coordinator()
        for coordinator in [aCoordinator, bCoordinator, aCoordinator, bCoordinator, aCoordinator] {
            bridge.mount(coordinator, in: host)
            expectEqual(host.subviews.count, 1)
            expectTrue(host.subviews.first === coordinator.scrollView)
            expectTrue(coordinator.textView.isDescendant(of: host))
        }
        EditorView.dismantleNSView(host, coordinator: bridge)
        expectTrue(host.subviews.isEmpty)
        expectTrue(aCoordinator.textView.undoManager !== bCoordinator.textView.undoManager)
        aCoordinator.detach()
        let reused = editor(a).makeSession()
        expectTrue(reused === aCoordinator)
        reused.synchronizeText()
        expectEqual(reused.textView.selectedRange().location, 2)
        reused.textView.undoManager?.undo()
        expectEqual(a.source, "A")
        expectEqual(b.source, "B!")
        reused.layoutManager.ensureLayout(for: reused.textContainer)
        expectEqual(reused.layoutManager.numberOfGlyphs, 1)
        a.dispose(); b.dispose()

        // Releasing a workspace must release its retained editor, even without explicit close.
        weak var releasedDocument: DocumentTab?
        weak var releasedEditor: EditorView.Session?
        autoreleasepool {
            let document = make("released")
            let coordinator = editor(document).makeSession()
            releasedDocument = document
            releasedEditor = coordinator
        }
        expectNil(releasedDocument)
        expectNil(releasedEditor)
    }

    @MainActor
    static func testFontConfigurationValidation() throws {
        let suite = "TypstEditTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CompilerSettings(defaults: defaults)
        expectTrue(settings.useSystemFonts)
        expectEqual(try settings.fontArguments(), [])
        settings.useSystemFonts = false
        settings.fontPaths = "/System/Library/Fonts\n/System/Library/Fonts/\n"
        expectEqual(try settings.fontArguments(), ["--ignore-system-fonts", "--font-path", "/System/Library/Fonts"])
        settings.fontPaths = "/missing-font-directory"
        expectThrows(try settings.fontArguments())
        settings.fontPaths = "relative"
        expectThrows(try settings.fontArguments())
    }

    @MainActor
    static func testPreviewLatestRequestWins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit PDF \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func pdf(_ name: String) throws -> URL {
            let document = PDFDocument()
            let bitmap = try unwrap(CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 800,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
            bitmap.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            let image = NSImage(cgImage: try unwrap(bitmap.makeImage()), size: NSSize(width: 200, height: 300))
            document.insert(try unwrap(PDFPage(image: image)), at: 0)
            let url = root.appendingPathComponent(name + ".pdf")
            expectTrue(document.write(to: url))
            return url
        }
        let first = try pdf("first"), latest = try pdf("latest")
        let coordinator = PreviewView.Coordinator()
        let view = PDFView()
        let token = UUID()
        coordinator.load(url: first, token: UUID(), in: view)
        coordinator.load(url: latest, token: token, in: view)
        for _ in 0..<50 where coordinator.lastURL != latest { try await Task.sleep(for: .milliseconds(20)) }
        expectEqual(coordinator.lastURL, latest)
        expectEqual(coordinator.lastToken, token)
        expectEqual(view.document?.pageCount, 1)
        coordinator.load(url: first, token: UUID(), in: view)
        coordinator.load(url: nil, token: nil, in: view)
        try await Task.sleep(for: .milliseconds(150))
        expectNil(view.document)
        expectNil(coordinator.lastURL)
        let retryURL = root.appendingPathComponent("retry.pdf")
        let retryToken = UUID()
        coordinator.load(url: retryURL, token: retryToken, in: view)
        try await Task.sleep(for: .milliseconds(150))
        try FileManager.default.copyItem(at: latest, to: retryURL)
        coordinator.load(url: retryURL, token: retryToken, in: view)
        for _ in 0..<50 where coordinator.lastURL != retryURL { try await Task.sleep(for: .milliseconds(20)) }
        expectEqual(coordinator.lastURL, retryURL)
    }

    @MainActor
    static func testVisibleSyntaxUsesTemporaryDrawingAttributes() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 1000))
        view.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        view.string = String(repeating: "#let value = 1\n", count: 100)
        scroll.documentView = view
        let source = view.string
        let originalAttributes = view.textStorage?.attributes(at: 1, effectiveRange: nil)
        let highlighter = SyntaxHighlighter()
        highlighter.install(SyntaxHighlighter.spans(in: source), in: view)
        expectEqual(view.string, source)
        expectTrue(view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 1, effectiveRange: nil) != nil)
        expectTrue(view.textStorage?.attribute(.font, at: 1, effectiveRange: nil) as? NSFont == originalAttributes?[.font] as? NSFont)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
        highlighter.renderVisible(in: view)
        expectNil(view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 1, effectiveRange: nil))
        highlighter.invalidate()
    }

    @MainActor
    static func testMarkedTextDefersBindingAndCompile() {
        var source = "prefix"
        var compileCalls = 0
        let controller = EditorController()
        let editor = EditorView(text: Binding(get: { source }, set: { source = $0 }), controller: controller, onCommit: { compileCalls += 1 })
        let coordinator = EditorView.Session(editor)
        let view = coordinator.textView
        view.string = source
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 6, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        expectTrue(view.hasMarkedText())
        expectEqual(source, "prefix")
        expectEqual(compileCalls, 0)
        view.insertText("你", replacementRange: view.markedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        expectFalse(view.hasMarkedText())
        expectEqual(source, "prefix你")
        expectTrue(compileCalls > 0)
        let reference = LineNumberRulerView(scrollView: nil, orientation: .verticalRuler)
        reference.updateLineStarts(view.string)
        expectEqual(coordinator.ruler.lineStarts, reference.lineStarts)
    }

    @MainActor
    static func testLowMemoryPreviewReleasesCompiler() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit low memory \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.typ")
        try "Saved".write(to: file, atomically: true, encoding: .utf8)
        let suite = "TypstEditTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CompilerSettings(defaults: defaults)
        settings.choice = .bundled
        settings.lowMemoryMode = true
        settings.useSystemFonts = false
        let compiler = TypstCompiler(settings: settings)
        defer { compiler.cleanUp() }
        for content in ["First revision", "Second revision"] {
            await compiler.updateContent(source: content, fileURL: file, projectFolder: root)
            for _ in 0..<100 where compiler.isCompiling { try await Task.sleep(for: .milliseconds(100)) }
            expectFalse(compiler.hasRunningProcess)
            let pdf = try unwrap(compiler.previewURL)
            expectTrue(PDFDocument(url: pdf)?.string?.contains(content) == true)
        }
    }

    @MainActor
    static func testRapidPreviewRequestsKeepLatestRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit rapid \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.typ")
        try "Saved".write(to: file, atomically: true, encoding: .utf8)
        let suite = "TypstEditTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CompilerSettings(defaults: defaults)
        settings.choice = .bundled
        settings.useSystemFonts = false
        for lowMemory in [false, true] {
            settings.lowMemoryMode = lowMemory
            let compiler = TypstCompiler(settings: settings)
            var requests: [Task<Void, Never>] = []
            for revision in 0..<12 {
                requests.append(Task { @MainActor in
                    await compiler.updateContent(source: "Revision \(revision)", fileURL: file, projectFolder: root)
                })
            }
            for request in requests { await request.value }
            // Explicit final request removes any dependence on scheduler ordering.
            await compiler.updateContent(source: "Latest revision", fileURL: file, projectFolder: root)
            for _ in 0..<100 {
                if let pdf = compiler.previewURL, PDFDocument(url: pdf)?.string?.contains("Latest revision") == true { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            expectTrue(PDFDocument(url: try unwrap(compiler.previewURL))?.string?.contains("Latest revision") == true)
            compiler.cleanUp()
            for _ in 0..<50 {
                if !(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains(where: { $0.hasPrefix(".typstedit") }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            expectFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".typstedit") })
        }
    }

    @MainActor
    static func testRealCompileRelativeCrossFolderImportsAndExportFailurePreservesPDF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit tests \(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chapters"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shared"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("chapters/main.typ")
        try "#let value = [Import succeeded]".write(to: root.appendingPathComponent("shared/module.typ"), atomically: true, encoding: .utf8)
        try "saved version".write(to: sourceURL, atomically: true, encoding: .utf8)
        let suite = "TypstEditTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CompilerSettings(defaults: defaults)
        settings.choice = .bundled
        let compiler = TypstCompiler(settings: settings)
        let output = root.appendingPathComponent("export.pdf")
        for path in ["../shared/module.typ", "/shared/module.typ"] {
            try await compiler.export(source: "#import \"\(path)\": value\n#value\nUnsaved revision", fileURL: sourceURL, projectFolder: root, destination: output)
            let document = try unwrap(PDFDocument(url: output))
            expectTrue(document.string?.contains("Import succeeded") == true)
            expectTrue(document.string?.contains("Unsaved revision") == true)
        }
        // Custom compiler paths with spaces are executed directly, without shell quoting.
        let custom = root.appendingPathComponent("custom typst")
        try FileManager.default.createSymbolicLink(atPath: custom.path, withDestinationPath: try unwrap(settings.bundledPath))
        settings.choice = .custom
        settings.customPath = custom.path
        await settings.refresh()
        expectTrue(settings.version.hasPrefix("typst "))
        expectNil(settings.detectionError)
        // A filesystem-absolute import works only with an explicitly selected / project root.
        settings.rootPath = "/"
        let absoluteImport = root.resolvingSymlinksInPath().appendingPathComponent("shared/module.typ").path
        try await compiler.export(source: "#import \"\(absoluteImport)\": value\n#value", fileURL: sourceURL, projectFolder: root, destination: output)
        expectTrue(PDFDocument(url: output)?.string?.contains("Import succeeded") == true)
        settings.rootPath = ""
        let previous = try Data(contentsOf: output)
        do {
            try await compiler.export(source: "#unknown-function()", fileURL: sourceURL, projectFolder: root, destination: output)
            fail("Invalid source should not export")
        } catch { expectEqual(try Data(contentsOf: output), previous) }
        expectEqual(try String(contentsOf: sourceURL, encoding: .utf8), "saved version")
        expectFalse(try FileManager.default.contentsOfDirectory(atPath: sourceURL.deletingLastPathComponent().path).contains { $0.hasPrefix(".typstedit") || $0.hasPrefix("typstedit-preview-") })
        settings.rootPath = root.appendingPathComponent("shared").path
        expectThrows(try settings.projectRoot(fileURL: sourceURL, folder: root))
    }

    @MainActor
    static func testWatchSuccessErrorRecoveryAndCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit watch \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.typ")
        try "Saved".write(to: file, atomically: true, encoding: .utf8)
        let suite = "TypstEditTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CompilerSettings(defaults: defaults)
        settings.choice = .bundled
        let compiler = TypstCompiler(settings: settings)
        defer { compiler.cleanUp() }
        await compiler.updateContent(source: "Hello watch", fileURL: file, projectFolder: root)
        for _ in 0..<100 where compiler.previewURL == nil { try await Task.sleep(for: .milliseconds(100)) }
        expectNotNil(compiler.previewURL)
        expectFalse(compiler.isCompiling)
        await compiler.updateContent(source: "#unknown-function()", fileURL: file, projectFolder: root)
        for _ in 0..<100 where compiler.errors.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        expectFalse(compiler.errors.isEmpty)
        await compiler.updateContent(source: "Recovered", fileURL: file, projectFolder: root)
        for _ in 0..<100 where compiler.isCompiling || !compiler.errors.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        expectTrue(compiler.errors.isEmpty)
        expectFalse(compiler.isCompiling)
        let pdf = compiler.previewURL
        compiler.cleanUp()
        for _ in 0..<100 where pdf.map({ FileManager.default.fileExists(atPath: $0.path) }) == true { try await Task.sleep(for: .milliseconds(50)) }
        expectFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".typstedit") || $0.hasPrefix("typstedit-preview-") })
        expectFalse(FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("pdf").path))
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    guard actual == expected else { fatalError("Expected \(expected), got \(actual)", file: file, line: line) }
}
private func expectTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    guard value else { fatalError("Expected true", file: file, line: line) }
}
private func expectFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) { expectTrue(!value, file: file, line: line) }
private func expectNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) { expectTrue(value == nil, file: file, line: line) }
private func expectNotNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) { expectTrue(value != nil, file: file, line: line) }
private func unwrap<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let value else { fatalError("Unexpected nil", file: file, line: line) }; return value
}
private func expectThrows<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try expression() } catch { return }
    fatalError("Expected an error", file: file, line: line)
}
private func fail(_ message: String, file: StaticString = #file, line: UInt = #line) { fatalError(message, file: file, line: line) }
