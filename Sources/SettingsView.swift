import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var language = LanguageSettings.shared
    @ObservedObject private var settings = CompilerSettings.shared
    var body: some View {
        Form {
            Section(L10n.text("Typst compiler", "Typst 编译器")) {
                Picker(L10n.text("Version source", "版本来源"), selection: $settings.choice) {
                    Text(L10n.text("Automatic (system first)", "自动检测（优先系统版本）")).tag(CompilerChoice.automatic)
                    Text(L10n.text("Bundled", "应用内置版本")).tag(CompilerChoice.bundled)
                    Text(L10n.text("Custom executable", "自选可执行文件")).tag(CompilerChoice.custom)
                }
                if settings.choice == .custom {
                    HStack {
                        TextField(L10n.text("Absolute path to typst", "Typst 的绝对路径"), text: $settings.customPath)
                        Button(L10n.text("Choose…", "选择…")) { chooseExecutable() }
                    }
                }
                HStack {
                    Text(settings.version.isEmpty ? L10n.text("Detecting…", "检测中…") : settings.version)
                    Spacer()
                    Button(L10n.text("Detect again", "重新检测")) { Task { await settings.refresh() } }
                }
                if let path = settings.executablePath {
                    Text(path).font(.caption).textSelection(.enabled)
                }
                if let error = settings.detectionError { Text(error).foregroundColor(.red) }
            }
            Section(L10n.text("Import paths", "引用路径")) {
                HStack {
                    TextField(L10n.text("Project root", "项目根目录"), text: $settings.rootPath,
                              prompt: Text(L10n.text("Empty = opened folder", "留空使用打开的文件夹")))
                    Button(L10n.text("Choose…", "选择…")) { chooseRoot() }
                }
                Button(L10n.text("Use opened folder", "使用打开的文件夹")) { settings.rootPath = "" }
                Text(L10n.text("Relative imports resolve beside each source file. Paths beginning with / resolve from this project root, not the macOS filesystem root. Select a common parent for imports across folders.", "相对引用从各源文件所在目录解析。/ 开头的路径从项目根目录解析，不是 macOS 的根目录。跨文件夹引用请选共同的上级目录。"))
                    .font(.caption).foregroundColor(.secondary)
            }
            Section(L10n.text("Performance", "性能")) {
                Toggle(L10n.text("Lower idle memory", "降低空闲内存占用"), isOn: $settings.lowMemoryMode)
                Text(L10n.text("Compiles after editing and releases the compiler after each build. Uses less idle memory but rebuilds are slower; external changes to imported files need Refresh Preview. Off: incremental compilation and automatic dependency watching.", "编辑后编译，每次结束释放编译器；空闲内存更低，但重复编译较慢。引用文件在外部修改后需手动刷新预览。关闭时使用增量编译，并自动监听引用文件。"))
                    .font(.caption).foregroundColor(.secondary)
                DisclosureGroup(L10n.text("Font discovery", "字体扫描")) {
                    Toggle(L10n.text("Scan system fonts", "扫描系统字体"), isOn: $settings.useSystemFonts)
                    TextEditor(text: $settings.fontPaths).font(.system(.caption, design: .monospaced)).frame(height: 60)
                    Button(L10n.text("Add font folder…", "添加字体文件夹…")) { chooseFonts() }
                    Text(L10n.text("One absolute folder path per line. Disabling system fonts can speed up startup; add folders containing all fonts your document needs, including Chinese and emoji. Typst's embedded fonts remain available.", "每行填写一个字体文件夹的绝对路径。关闭系统字体扫描可加快启动；请加入文档所需字体的目录，包括中文和 emoji。Typst 内嵌字体仍可使用。"))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Section(L10n.text("Language Assistance", "语言辅助")) {
                Toggle(L10n.text("Enable Tinymist", "启用 Tinymist"), isOn: $language.enabled)
                Toggle(L10n.text("Automatic completion", "自动补全"), isOn: $language.autoComplete)
                Toggle(L10n.text("Hover documentation", "悬浮文档提示"), isOn: $language.hover)
                Toggle(L10n.text("Format on Save", "保存时格式化"), isOn: $language.formatOnSave)
                HStack {
                    TextField(L10n.text("Tinymist path (empty = detect)", "Tinymist 路径（留空自动检测）"), text: $language.customPath)
                    Button(L10n.text("Choose…", "选择…")) { chooseLanguageServer() }
                }
                Text(language.executable ?? L10n.text("Tinymist not found; install with brew install tinymist or select an executable.", "未找到 Tinymist；可使用 brew install tinymist 安装，或选择已有可执行文件。"))
                    .font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                Text(L10n.text("Option+Esc completes; Shift+Option+F formats. Runs on demand and exits after 60 seconds without requests. Save formatting applies to Cmd+S and Auto Save; closing prompts save the draft immediately. Language-service and PDF-compiler versions are independent.", "Option+Esc 补全，Shift+Option+F 格式化。按需启动，60 秒无请求后释放。保存时格式化用于 Cmd+S 和自动保存；关闭确认直接保存草稿。语言服务与 PDF 编译器版本独立。"))
                    .font(.caption).foregroundColor(.secondary)
            }
            Section(L10n.text("Editing", "编辑")) {
                Toggle(L10n.text("Auto Save", "自动保存"), isOn: $settings.autoSaveEnabled)
                Text(L10n.text("Save after 1 second without typing. Compilation errors do not prevent saving. External file changes pause saving and retain your draft.", "停止输入 1 秒后保存，编译错误不影响保存。检测到外部修改时暂停保存并保留草稿。"))
                    .font(.caption).foregroundColor(.secondary)
                Text(L10n.text("Interface follows your macOS language (Chinese or English). Chinese input uses the native input method. PDF fonts and language are controlled by your Typst document.", "界面跟随 macOS 语言（中文或英文），中文输入使用原生输入法。PDF 字体及语言由 Typst 文档设置。"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 700)
        .task(id: settings.choice.rawValue + settings.customPath) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await settings.refresh()
        }
    }

    private func chooseLanguageServer() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = L10n.text("Choose Tinymist executable", "选择 Tinymist 可执行文件")
        if panel.runModal() == .OK, let url = panel.url { language.customPath = url.path }
    }
    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = L10n.text("Choose Typst executable", "选择 Typst 可执行文件")
        if panel.runModal() == .OK, let url = panel.url { settings.customPath = url.path }
    }
    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url { settings.rootPath = url.path }
    }
    private func chooseFonts() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let additions = panel.urls.map(\.path).joined(separator: "\n")
            settings.fontPaths = [settings.fontPaths, additions].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }
}
