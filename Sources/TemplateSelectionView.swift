import SwiftUI

struct TemplateSelectionView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var themeManager: ThemeManager
    var onSelect: (ProjectTemplate) -> Void
    
    let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 160), spacing: 20)
    ]
    
    var body: some View {
        VStack(spacing: 20) {
            headerView
            scrollView
            cancelButton
        }
        .frame(width: 600, height: 500)
        .background(themeManager.mainBackground)
    }
    
    var headerView: some View {
        Text(L10n.text("Choose a Template", "选择模板"))
            .font(.title2)
            .fontWeight(.bold)
            .foregroundColor(themeManager.textColor)
            .padding(.top, 20)
    }
    
    var scrollView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(ProjectTemplates.all) { template in
                    templateButton(for: template)
                }
            }
            .padding(20)
        }
    }
    
    func templateButton(for template: ProjectTemplate) -> some View {
        Button(action: {
            onSelect(template)
            dismiss()
        }) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.1))
                        .frame(width: 60, height: 60)
                    
                    Image(systemName: template.icon)
                        .font(.system(size: 30))
                        .foregroundColor(.blue)
                }
                
                VStack(spacing: 4) {
                    Text(template.name)
                        .font(.headline)
                        .foregroundColor(themeManager.textColor)
                    
                    Text(template.description)
                        .font(.caption)
                        .foregroundColor(themeManager.textColor.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovering in
            if isHovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
    
    var cancelButton: some View {
        Button(L10n.text("Cancel", "取消")) {
            dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .padding(.bottom, 20)
    }
}
