import SwiftUI

struct WelcomeView: View {
    @ObservedObject var model: FileSystemModel
    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject var recents = RecentFilesManager.shared
    var onOpen: (URL) -> Void
    
    @State private var showingTemplateSelection = false
    
    var body: some View {
        HStack(spacing: 0) {
            // Left Panel: Actions (Centered)
            VStack(spacing: 30) {
                Spacer()
                Image(systemName: "doc.text.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .foregroundColor(.white.opacity(0.8))
                    .shadow(radius: 10)
                
                Text(L10n.text("Welcome to TypstEdit", "欢迎使用 TypstEdit"))
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(themeManager.textColor)
                
                Text(L10n.text("Create beautiful documents with the power of Typst.", "使用 Typst 创作精美文档。"))
                    .font(.body)
                    .foregroundColor(themeManager.textColor.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                HStack(spacing: 20) {
                    Button(action: { showingTemplateSelection = true }) {
                        VStack {
                            Image(systemName: "plus.square.fill")
                                .font(.system(size: 24))
                                .padding(.bottom, 5)
                                .foregroundColor(.blue)
                            Text(L10n.text("New Project", "新建项目"))
                                .font(.headline)
                                .foregroundColor(themeManager.textColor)
                        }
                        .frame(width: 140, height: 100)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { model.openFolder() }) {
                        VStack {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 24))
                                .padding(.bottom, 5)
                                .foregroundColor(.blue)
                            Text(L10n.text("Open Project", "打开项目"))
                                .font(.headline)
                                .foregroundColor(themeManager.textColor)
                        }
                        .frame(width: 140, height: 100)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 20)
                
                Button(L10n.text("Open Finder", "打开访达")) {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.currentFolder?.path ?? FileManager.default.homeDirectoryForCurrentUser.path)
                }
                .buttonStyle(.link)
                .foregroundColor(themeManager.textColor.opacity(0.7))
                Spacer()
            }
            .frame(maxWidth: .infinity)
            
            // Divider
            Rectangle().fill(Color.black.opacity(0.2)).frame(width: 1)
            
            // Right Panel: Recent Files
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.text("Recent Files", "最近文件"))
                    .font(.headline)
                    .foregroundColor(themeManager.textColor)
                    .padding()
                    .padding(.top, 20)
                
                List {
                    ForEach(recents.recentFiles) { file in
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading) {
                                Text(file.name)
                                    .foregroundColor(themeManager.textColor)
                                .truncationMode(.middle)
                                Text(file.path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onOpen(file.url)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .frame(width: 250)
            .background(Color.black.opacity(0.1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.mainBackground.ignoresSafeArea())
        .sheet(isPresented: $showingTemplateSelection) {
            TemplateSelectionView { template in
                model.createNewProject(template: template)
            }
            .environmentObject(themeManager)
        }
    }
}
