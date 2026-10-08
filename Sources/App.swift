import SwiftUI

@main
struct TypstEditApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @StateObject private var themeManager = ThemeManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(themeManager)
                // Applique l'effet de flou (Acrylic/Vibrancy) à tout le fond de la fenêtre
                .background(VisualEffectView().ignoresSafeArea())
        }
        .windowStyle(.hiddenTitleBar) // Cache la barre de titre native opaque
        .windowToolbarStyle(.unified) // Unifie la barre d'outils avec le contenu
        .commands {
            AppMenuCommands()
        }
        Settings {
            SettingsView()
        }
    }
}
