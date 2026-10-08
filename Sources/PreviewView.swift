import SwiftUI
import PDFKit

struct PreviewView: NSViewRepresentable {
    var url: URL?
    var reloadToken: UUID?
    @EnvironmentObject var themeManager: ThemeManager

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        view.backgroundColor = NSColor(themeManager.pdfBackground)
        view.appearance = NSAppearance(named: .darkAqua)
        context.coordinator.load(url: url, token: reloadToken, in: view)
    }
    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.load(url: nil, token: nil, in: view)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    @MainActor class Coordinator {
        var lastURL: URL?
        var lastToken: UUID?
        private var requestedURL: URL?
        private var requestedToken: UUID?
        private var generation = 0
        private var task: Task<Void, Never>?

        deinit { task?.cancel() }

        func load(url: URL?, token: UUID?, in view: PDFView) {
            guard requestedURL != url || requestedToken != token else { return }
            requestedURL = url
            requestedToken = token
            generation &+= 1
            let request = generation
            task?.cancel()
            guard let url else {
                view.document = nil
                lastURL = nil
                lastToken = nil
                return
            }
            task = Task { @MainActor [weak self, weak view] in
                // Coalesce bursts before allocating another immutable PDF snapshot.
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                let data = await PDFSnapshotReader.shared.read(url)
                guard !Task.isCancelled, let self, let view, self.generation == request else { return }
                defer { self.task = nil }
                // PDFKit view/document mutation remains on the main actor.
                guard let data, let document = autoreleasepool(invoking: { PDFDocument(data: data) }) else {
                    self.requestedURL = nil
                    self.requestedToken = nil
                    return
                }
                let sameFile = self.lastURL == url
                let point = view.currentDestination?.point ?? .zero
                let index = view.currentPage.map { view.document?.index(for: $0) ?? 0 } ?? 0
                let scale = view.scaleFactor
                let autoScales = view.autoScales
                view.document = document
                if sameFile {
                    view.autoScales = autoScales
                    if !autoScales { view.scaleFactor = scale }
                    if let page = document.page(at: min(index, max(0, document.pageCount - 1))) {
                        view.go(to: PDFDestination(page: page, at: point))
                    }
                } else { view.autoScales = true }
                self.lastURL = url
                self.lastToken = token
            }
        }
    }
}

private actor PDFSnapshotReader {
    static let shared = PDFSnapshotReader()
    func read(_ url: URL) -> Data? {
        guard !Task.isCancelled else { return nil }
        return autoreleasepool { try? Data(contentsOf: url) }
    }
}
