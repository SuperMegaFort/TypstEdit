import SwiftUI
import AppKit

// A native NSButton wrapper that shows the SharingServicePicker relative to itself
struct ShareButton: NSViewRepresentable {
    var fileURL: URL?
    
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: L10n.text("Share", "分享"))!, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.bezelStyle = .texturedRounded
        button.toolTip = L10n.text("Share", "分享")
        return button
    }
    
    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.parent = self
        nsView.isEnabled = fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSSharingServicePickerDelegate {
        var parent: ShareButton
        
        init(_ parent: ShareButton) {
            self.parent = parent
        }
        
        @objc func clicked(_ sender: NSButton) {
            
            guard let url = parent.fileURL else {
                return
            }
            
            let picker = NSSharingServicePicker(items: [url])
            picker.delegate = self
            // This anchors the picker to the button
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
