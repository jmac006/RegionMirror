//
//  RegionMirrorEngine.swift
//  RegionMirror
//
//  Created by Justin Mac on 9/3/25.
//

import AppKit
@preconcurrency import ScreenCaptureKit
import AVFoundation
import CoreGraphics
import QuartzCore

// MARK: - Helpers

extension NSScreen {
    /// Which screen is the mouse currently on?
    static func screenUnderMouse() -> NSScreen {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(loc) })
        ?? NSScreen.main ?? NSScreen.screens.first!
    }
    /// CGDirectDisplayID for matching to ScreenCaptureKit SCDisplay.
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
    }
}

/// Snap a rect in *points* so its edges fall exactly on device pixels for a given scale.
extension CGRect {
    func snappedToDevicePixels(scale: CGFloat) -> CGRect {
        let x = round(self.origin.x * scale) / scale
        let y = round(self.origin.y * scale) / scale
        let w = round(self.size.width * scale) / scale
        let h = round(self.size.height * scale) / scale
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

struct AppState {
    var selectedRegion: CGRect = .zero
    var isCapturing = false
}

// MARK: - Selection Overlay (Cmd+Shift+5 style)

final class SelectionOverlayWindow: NSWindow {
    private var startPoint: NSPoint?
    private var shapeLayer: CAShapeLayer?
    private let targetScale: CGFloat
    var onSelectionComplete: ((CGRect) -> Void)?

    init(on screen: NSScreen) {
        self.targetScale = screen.backingScaleFactor
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.25) // visible & receives events
        ignoresMouseEvents = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = false

        let overlayView = NSView(frame: contentLayoutRect)
        overlayView.wantsLayer = true
        contentView = overlayView
    }

    override var canBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) {
        startPoint = contentView!.convert(event.locationInWindow, from: nil)
        shapeLayer?.removeFromSuperlayer()
        shapeLayer = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let sp = startPoint else { return }
        let p = contentView!.convert(event.locationInWindow, from: nil)
        let rect = CGRect(x: min(sp.x, p.x), y: min(sp.y, p.y),
                          width: abs(sp.x - p.x), height: abs(sp.y - p.y))
        updateSelectionHole(rect: rect)
    }

    override func mouseUp(with event: NSEvent) {
        guard let sp = startPoint else { return close() }
        let p = contentView!.convert(event.locationInWindow, from: nil)
        var rect = CGRect(x: min(sp.x, p.x), y: min(sp.y, p.y),
                          width: abs(sp.x - p.x), height: abs(sp.y - p.y))
        if rect.width > 10 && rect.height > 10 {
            rect = rect.snappedToDevicePixels(scale: targetScale)
            onSelectionComplete?(rect)
        }
        close()
    }

    private func updateSelectionHole(rect: CGRect) {
        let path = CGMutablePath()
        path.addRect(contentView!.bounds)
        path.addRect(rect) // even-odd hole

        if shapeLayer == nil {
            let s = CAShapeLayer()
            s.fillRule = .evenOdd
            s.fillColor = NSColor.black.withAlphaComponent(0.40).cgColor
            contentView!.layer?.addSublayer(s)
            shapeLayer = s
        }
        shapeLayer?.path = path
    }
}

// MARK: - Crisp Shareable Window (ScreenCaptureKit)

final class MirrorWindow: NSWindow, SCStreamOutput, SCStreamDelegate, NSWindowDelegate {
    fileprivate let displayLayer = AVSampleBufferDisplayLayer()
    private var stream: SCStream?
    weak var presenter: Presenter?

    init(contentRect: CGRect, presenter: Presenter) {
        self.presenter = presenter
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable], // minimizable
            backing: .buffered,
            defer: false
        )
        title = "RegionMirror"
        isReleasedWhenClosed = true
        delegate = self

        // Host layer
        contentView?.wantsLayer = true
        contentView!.layer?.masksToBounds = true
        contentView!.layer?.allowsGroupOpacity = false

        // Preview layer: pixel-perfect & unfiltered
        displayLayer.isOpaque = true
        displayLayer.videoGravity = .resize                 // no extra scaling
        displayLayer.magnificationFilter = .nearest
        displayLayer.minificationFilter  = .nearest
        displayLayer.allowsEdgeAntialiasing = false

        // Add layer
        contentView!.layer?.addSublayer(displayLayer)

        // Initial alignment & scale
        applyScaleFromCurrentScreen()

        // Keep alignment on resize
        contentView?.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
            guard let self = self, let cv = self.contentView else { return }
            self.displayLayer.frame = cv.backingAlignedRect(cv.bounds, options: .alignAllEdgesNearest)
        }
        // Update scale if window moves to a screen with a different backing scale
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: self, queue: .main) { [weak self] _ in
            self?.applyScaleFromCurrentScreen()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification, object: self, queue: .main) { [weak self] _ in
            self?.applyScaleFromCurrentScreen()
        }

        center()
        makeKeyAndOrderFront(nil)
    }

    private func applyScaleFromCurrentScreen() {
        let s = (self.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor) ?? 2.0
        self.contentView?.layer?.contentsScale = s
        self.displayLayer.contentsScale = s
        // Align to pixel grid
        if let cv = self.contentView {
            self.displayLayer.frame = cv.backingAlignedRect(cv.bounds, options: .alignAllEdgesNearest)
        }
        // Snap resizes to device pixels to avoid blur when the user drags the window edges
        self.contentResizeIncrements = NSSize(width: 1 / s, height: 1 / s)
    }

    @MainActor
    func startCapture(for scDisplay: SCDisplay, on screen: NSScreen, region: CGRect, excludingApplications: [SCRunningApplication]) async {
        // Convert selection (points) → integer pixels; ScreenCaptureKit uses top-left origin
        let scale = screen.backingScaleFactor
        let x_px = Int(round(region.origin.x * scale))
        let y_px = Int(round((screen.frame.height - region.origin.y - region.height) * scale)) // flip Y
        let w_px = max(16, Int(round(region.width * scale)))
        let h_px = max(16, Int(round(region.height * scale)))
        let pixelRect = CGRect(x: x_px, y: y_px, width: w_px, height: h_px)

        // Pixel-perfect window size (1:1)
        let sizePoints = NSSize(width: CGFloat(w_px) / scale, height: CGFloat(h_px) / scale)
        self.setContentSize(sizePoints)
        self.contentAspectRatio = sizePoints
        self.applyScaleFromCurrentScreen()

        // Configure the stream at exact pixel dimensions
        let cfg = SCStreamConfiguration()
        cfg.width  = w_px
        cfg.height = h_px
        cfg.showsCursor = true
        cfg.sourceRect = pixelRect
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.queueDepth = 5

        let filter = SCContentFilter(display: scDisplay,
                                     excludingApplications: excludingApplications,
                                     exceptingWindows: [])

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            try await stream.startCapture()
            self.stream = stream
        } catch {
            Task { @MainActor in self.presenter?.showError("Failed to start capture: \(error.localizedDescription)") }
        }
    }

    func stopCapture() {
        Task { @MainActor in
            try? await stream?.stopCapture()
            stream = nil
        }
    }

    // SCStreamOutput: feed frames (macOS 15 deprecation warnings are OK)
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        if displayLayer.isReadyForMoreMediaData { displayLayer.enqueue(sampleBuffer) }
    }

    // Surface errors on main
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.presenter?.showError("Screen capture stopped: \(error.localizedDescription)")
            self.stopCapture()
        }
    }

    func windowWillClose(_ notification: Notification) { presenter?.stopCapture() }
}

// MARK: - Presenter (App logic for SwiftUI)

@MainActor
final class Presenter: ObservableObject {
    private var model = AppState()
    private var selectionOverlay: SelectionOverlayWindow?
    private var mirrorWindow: MirrorWindow?

    func startSelection() {
        // NOTE: Do not block on preflight; Ventura/Sonoma/Sequoia may require app relaunch after toggling.
        // We still request access to trigger the prompt if needed, but continue to selection.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            // We do NOT early-return here; proceed and let the stream start surface a precise error if needed.
        }

        let targetScreen = NSScreen.screenUnderMouse()
        let overlay = SelectionOverlayWindow(on: targetScreen)
        overlay.onSelectionComplete = { [weak self] rect in
            guard let self = self else { return }
            self.model.selectedRegion = rect
            self.startMirroring(on: targetScreen, region: rect)
        }
        selectionOverlay = overlay
        overlay.makeKeyAndOrderFront(nil)
        overlay.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startMirroring(on screen: NSScreen, region: CGRect) {
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.current
                // Match SCDisplay to this NSScreen via CGDirectDisplayID.
                guard let scDisplay = content.displays.first(where: { $0.displayID == screen.displayID }) ?? content.displays.first else {
                    showError("Could not match the selected display.")
                    return
                }
                // Try to exclude our own app; if we can’t find it, proceed without exclusions.
                let myBundleID = Bundle.main.bundleIdentifier
                let excludedApps = content.applications.filter { $0.bundleIdentifier == myBundleID }

                // Create / show mirror window and start capture.
                self.mirrorWindow?.close()
                let mirror = MirrorWindow(contentRect: region, presenter: self)
                self.mirrorWindow = mirror
                await mirror.startCapture(for: scDisplay, on: screen, region: region, excludingApplications: excludedApps)

                self.model.isCapturing = true
            } catch {
                // If this fails with a permission error, guide the user to Settings.
                showError("""
                Failed to enumerate displays: \(error.localizedDescription)
                If you just enabled “Screen & System Audio Recording”, you may need to quit and relaunch the app.
                You can also open the Settings pane from RegionMirror > Help > Open Screen Recording Settings.
                """)
            }
        }
    }

    func stopCapture() {
        mirrorWindow?.stopCapture()
        mirrorWindow = nil
        model.isCapturing = false
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "RegionMirror"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApp.activate(ignoringOtherApps: true)
    }

    // Convenience to deep-link to the privacy pane (you can call this from a menu item)
    func openScreenRecordingSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording"
        ]
        for c in candidates {
            if let url = URL(string: c), NSWorkspace.shared.open(url) { return }
        }
    }
}
