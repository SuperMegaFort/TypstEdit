import SwiftUI

struct ToolbarView: View {
    @ObservedObject var controller: EditorController
    
    var body: some View {
        HStack(spacing: 0) {
            // Text formatting
            Group {
                ToolbarButton(icon: "bold", action: controller.toggleBold)
                ToolbarButton(icon: "italic", action: controller.toggleItalic)
                ToolbarButton(icon: "underline", action: { controller.wrapSelection(prefix: "#underline[", suffix: "]") })
            }
            
            Rectangle().fill(Color.clear).frame(width: 12, height: 1)
            
            // Snippets
            Group {
                ToolbarButton(icon: "tablecells", action: controller.insertTableSnippet)
                ToolbarButton(icon: "photo", action: controller.insertImageSnippet)
                ToolbarButton(icon: "chart.bar", action: controller.insertChartSnippet)
                ToolbarButton(icon: "calendar", action: controller.insertTimelineSnippet)
            }
            
            Rectangle().fill(Color.clear).frame(width: 12, height: 1)
            
            // Other formatting
            Group {
                ToolbarButton(text: "H", action: controller.insertHeading)
                ToolbarButton(icon: "function", action: controller.insertMath)
                ToolbarButton(icon: "chevron.left.forwardslash.chevron.right", action: controller.toggleCode)
            }
        }
    }
}

struct ToolbarButton: View {
    var icon: String?
    var text: String?
    var action: () -> Void
    @State private var isHovering = false
    
    private var accessibilityTitle: String {
        switch icon ?? text ?? "" {
        case "bold": return L10n.text("Bold", "加粗")
        case "italic": return L10n.text("Italic", "斜体")
        case "underline": return L10n.text("Underline", "下划线")
        case "tablecells": return L10n.text("Insert table", "插入表格")
        case "photo": return L10n.text("Insert image", "插入图片")
        case "chart.bar": return L10n.text("Insert chart", "插入图表")
        case "calendar": return L10n.text("Insert timeline", "插入时间线")
        case "H": return L10n.text("Heading", "标题")
        case "function": return L10n.text("Math", "数学公式")
        default: return L10n.text("Code", "代码")
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                } else if let text = text {
                    Text(text)
                        .font(.system(size: 14, weight: .bold))
                }
            }
            .frame(width: 28, height: 28)
            .background(isHovering ? Color.primary.opacity(0.1) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(accessibilityTitle)
        .accessibilityLabel(accessibilityTitle)
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}
