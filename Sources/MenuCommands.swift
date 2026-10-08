import SwiftUI

struct DocumentActions {
    let open: () -> Void
    let save: () -> Void
    let export: () -> Void
    let refresh: () -> Void
    let insert: (String) -> Void
    let complete: () -> Void
    let format: () -> Void
    let hasDocument: Bool
}
struct DocumentActionsKey: FocusedValueKey { typealias Value = DocumentActions }
extension FocusedValues {
    var documentActions: DocumentActions? {
        get { self[DocumentActionsKey.self] }
        set { self[DocumentActionsKey.self] = newValue }
    }
}

struct AppMenuCommands: Commands {
    @FocusedValue(\.documentActions) private var actions
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.text("Open Typst File…", "打开 Typst 文件…")) { actions?.open() }
                .keyboardShortcut("o", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button(L10n.text("Save", "保存")) { actions?.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(actions?.hasDocument != true)
            Button(L10n.text("Export PDF…", "导出 PDF…")) { actions?.export() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions?.hasDocument != true)
        }
        CommandGroup(after: .textEditing) {
            Button(L10n.text("Complete Typst", "Typst 自动补全")) { actions?.complete() }
                .keyboardShortcut(.escape, modifiers: .option).disabled(actions?.hasDocument != true)
            Button(L10n.text("Format Document", "格式化文档")) { actions?.format() }
                .keyboardShortcut("f", modifiers: [.option, .shift]).disabled(actions?.hasDocument != true)
        }
        CommandMenu(L10n.text("Preview", "预览")) {
            Button(L10n.text("Refresh Preview", "刷新预览")) { actions?.refresh() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.hasDocument != true)
        }
        CommandMenu(L10n.text("Insert", "插入")) {
            Button(L10n.text("Table", "表格")) { actions?.insert("table") }
            Button(L10n.text("Image", "图片")) { actions?.insert("image") }
            Button(L10n.text("Chart", "图表")) { actions?.insert("chart") }
            Button(L10n.text("Timeline", "时间线")) { actions?.insert("timeline") }
        }
    }
}

