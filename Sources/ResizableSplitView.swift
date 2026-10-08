import SwiftUI
import AppKit

// Custom NSSplitView subclass to customize divider
class CustomSplitView: NSSplitView {
    override var dividerThickness: CGFloat {
        return 8
    }
    
    override func drawDivider(in rect: NSRect) {
        // Draw transparent divider
        NSColor.clear.setFill()
        rect.fill()
    }
}

struct ResizableSplitView<Left: View, Right: View>: NSViewRepresentable {
    let left: Left
    let right: Right
    let showsRight: Bool
    
    init(initialWidth: CGFloat = 500, showsRight: Bool = true, @ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.showsRight = showsRight
        self.left = left()
        self.right = right()
    }
    
    func makeNSView(context: Context) -> CustomSplitView {
        let splitView = CustomSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        
        // Create hosting controllers for SwiftUI views
        let leftHost = NSHostingController(rootView: left)
        let rightHost = NSHostingController(rootView: right)
        
        leftHost.view.translatesAutoresizingMaskIntoConstraints = false
        rightHost.view.translatesAutoresizingMaskIntoConstraints = false
        
        leftHost.view.wantsLayer = true
        rightHost.view.wantsLayer = true
        
        // Create container views
        let leftContainer = NSView()
        let rightContainer = NSView()
        
        leftContainer.addSubview(leftHost.view)
        rightContainer.addSubview(rightHost.view)
        
        // Add constraints
        NSLayoutConstraint.activate([
            leftHost.view.topAnchor.constraint(equalTo: leftContainer.topAnchor),
            leftHost.view.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor),
            leftHost.view.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor),
            leftHost.view.bottomAnchor.constraint(equalTo: leftContainer.bottomAnchor),
            
            rightHost.view.topAnchor.constraint(equalTo: rightContainer.topAnchor),
            rightHost.view.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            rightHost.view.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            rightHost.view.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor)
        ])
        
        splitView.addArrangedSubview(leftContainer)
        splitView.addArrangedSubview(rightContainer)
        rightContainer.isHidden = !showsRight
        
        // Add constraint to encourage 50/50 split initially (Priority 250 - Low)
        let equalWidth = leftContainer.widthAnchor.constraint(equalTo: rightContainer.widthAnchor)
        equalWidth.priority = .defaultLow
        equalWidth.isActive = true
        
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        
        context.coordinator.leftHost = leftHost
        context.coordinator.rightHost = rightHost
        
        return splitView
    }
    
    func updateNSView(_ nsView: CustomSplitView, context: Context) {
        // Update hosting controllers with new SwiftUI views
        context.coordinator.leftHost?.rootView = left
        context.coordinator.rightHost?.rootView = right
        if let pane = nsView.arrangedSubviews.last, pane.isHidden == showsRight {
            pane.isHidden = !showsRight
            nsView.adjustSubviews()
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var leftHost: NSHostingController<Left>?
        var rightHost: NSHostingController<Right>?
    }
}
