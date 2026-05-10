import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
typealias PlatformShareViewController = NSViewController
#else
import UIKit
typealias PlatformShareViewController = UIViewController
#endif

/// Entry point for the R2 Vault Share Extension.
/// Reads shared files/images from the incoming NSExtensionContext, copies them
/// into the shared App Group container, then saves a pending-upload record so
/// the host app can pick it up on next launch (or when it next becomes active).
class ShareViewController: PlatformShareViewController {
    private static let appGroupID = "group.fiaxe.r2Vault"
    private let maxInMemoryFallbackSize = 32 * 1024 * 1024

    private struct PendingShareFile {
        let sourceURL: URL
        let fileName: String
    }

    // MARK: - View lifecycle

#if os(macOS)
    override func loadView() {
        let shareView = ShareView(onCancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: ShareError.cancelled)
        })
        let host = NSHostingView(rootView: shareView)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
        self.view = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await extractAndQueue() }
    }
#else
    override func viewDidLoad() {
        super.viewDidLoad()
        let shareView = ShareView(onCancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: ShareError.cancelled)
        })
        let host = UIHostingController(rootView: shareView)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await extractAndQueue() }
    }
#endif

    // MARK: - File extraction

    private func extractAndQueue() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        let inboxURL = containerURL.appendingPathComponent("ShareInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)

        var copiedURLs: [URL] = []

        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if let sharedFile = await loadFileURL(from: provider) {
                    let dest = uniqueDestinationURL(for: sharedFile.fileName, in: inboxURL)
                    do {
                        try FileManager.default.copyItem(at: sharedFile.sourceURL, to: dest)
                        copiedURLs.append(dest)
                    } catch {
                        // Skip files we can't copy
                    }
                }
            }
        }

        // Persist the list of pending URLs to UserDefaults (shared suite)
        if !copiedURLs.isEmpty {
            let defaults = UserDefaults(suiteName: Self.appGroupID)
            var pending = defaults?.stringArray(forKey: "pendingShareURLs") ?? []
            pending.append(contentsOf: copiedURLs.map(\.absoluteString))
            defaults?.set(pending, forKey: "pendingShareURLs")
        }

        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Attempts to load a file-backed URL from an NSItemProvider.
    private func loadFileURL(from provider: NSItemProvider) async -> PendingShareFile? {
        // Priority: load as a file representation first (works for Files / Finder).
        let fileTypes: [UTType] = [.image, .movie, .data, .fileURL]
        for type in fileTypes {
            if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                if let fileURL = await loadFileRepresentation(from: provider, type: type) {
                    return fileURL
                }

                if let url = try? await provider.loadItem(forTypeIdentifier: type.identifier) as? URL {
                    return PendingShareFile(
                        sourceURL: url,
                        fileName: preferredFileName(for: provider, fallbackURL: url)
                    )
                }

                // Some providers give Data instead of URL
                if let data = try? await provider.loadItem(forTypeIdentifier: type.identifier) as? Data {
                    guard data.count <= maxInMemoryFallbackSize else { return nil }
                    let ext = type.preferredFilenameExtension ?? "bin"
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(ext)
                    try? data.write(to: tempURL)
                    return PendingShareFile(
                        sourceURL: tempURL,
                        fileName: preferredFileName(for: provider, fallbackURL: tempURL)
                    )
                }
            }
        }
        return nil
    }

    private func loadFileRepresentation(from provider: NSItemProvider, type: UTType) async -> PendingShareFile? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }

                let preferredName = self.preferredFileName(for: provider, fallbackURL: url)
                let ext = (preferredName as NSString).pathExtension.isEmpty
                    ? (type.preferredFilenameExtension ?? url.pathExtension)
                    : ""

                var tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                if !ext.isEmpty {
                    tempURL.appendPathExtension(ext)
                }

                do {
                    try FileManager.default.copyItem(at: url, to: tempURL)
                    continuation.resume(returning: PendingShareFile(sourceURL: tempURL, fileName: preferredName))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func preferredFileName(for provider: NSItemProvider, fallbackURL: URL) -> String {
        if let suggestedName = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggestedName.isEmpty {
            let pathExtension = fallbackURL.pathExtension
            if (suggestedName as NSString).pathExtension.isEmpty, !pathExtension.isEmpty {
                return suggestedName + ".\(pathExtension)"
            }
            return suggestedName
        }

        return fallbackURL.lastPathComponent
    }

    private func uniqueDestinationURL(for fileName: String, in directory: URL) -> URL {
        let baseName = (fileName as NSString).deletingPathExtension
        let pathExtension = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var index = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            let nextName = pathExtension.isEmpty
                ? "\(baseName) \(index)"
                : "\(baseName) \(index).\(pathExtension)"
            candidate = directory.appendingPathComponent(nextName)
            index += 1
        }

        return candidate
    }
}

// MARK: - SwiftUI overlay (progress / status)

private struct ShareView: View {
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.up.to.line.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Sending to R2 Vault…")
                .font(.headline)
            Text("Files will be uploaded the next time R2 Vault is open.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 320, minHeight: 220)
    }
}

// MARK: - Errors

private enum ShareError: Error {
    case cancelled
}
