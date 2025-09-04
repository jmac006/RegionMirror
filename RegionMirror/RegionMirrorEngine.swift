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
    private var isTearingDown = false

    init(contentRect: CGRect, presenter: Presenter) {
        self.presenter = presenter
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "RegionMirror"
        isReleasedWhenClosed = false // Important: We manage the lifecycle to prevent early release.
        delegate = self

        // Host layer
        contentView?.wantsLayer = true
        contentView!.layer?.masksToBounds = true
        contentView!.layer?.allowsGroupOpacity = false

        // Preview layer
        displayLayer.isOpaque = true
        displayLayer.videoGravity = .resize
        displayLayer.magnificationFilter = .nearest
        displayLayer.minificationFilter = .nearest
        displayLayer.allowsEdgeAntialiasing = false
        contentView!.layer?.addSublayer(displayLayer)

        // Initial alignment & scale
        applyScaleFromCurrentScreen()

        // Keep alignment on resize
        contentView?.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
            guard let self = self, let cv = self.contentView else { return }
            self.displayLayer.frame = cv.backingAlignedRect(cv.bounds, options: .alignAllEdgesNearest)
        }
        // Update scale on screen changes
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
        let s = (screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor) ?? 2.0
        contentView?.layer?.contentsScale = s
        displayLayer.contentsScale = s
        if let cv = contentView {
            displayLayer.frame = cv.backingAlignedRect(cv.bounds, options: .alignAllEdgesNearest)
        }
        contentResizeIncrements = NSSize(width: 1 / s, height: 1 / s)
    }

    @MainActor
    func startCapture(for scDisplay: SCDisplay, on screen: NSScreen, region: CGRect, excludingApplications: [SCRunningApplication]) async {
        let scale = screen.backingScaleFactor
        let x_px = Int(round(region.origin.x * scale))
        let y_px = Int(round((screen.frame.height - region.origin.y - region.height) * scale)) // flip Y
        let w_px = max(16, Int(round(region.width * scale)))
        let h_px = max(16, Int(round(region.height * scale)))
        let pixelRect = CGRect(x: x_px, y: y_px, width: w_px, height: h_px)

        let sizePoints = NSSize(width: CGFloat(w_px) / scale, height: CGFloat(h_px) / scale)
        setContentSize(sizePoints)
        contentAspectRatio = sizePoints
        applyScaleFromCurrentScreen()

        let cfg = SCStreamConfiguration()
        cfg.width = w_px
        cfg.height = h_px
        cfg.showsCursor = true
        cfg.sourceRect = pixelRect
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.queueDepth = 5

        let filter = SCContentFilter(display: scDisplay, excludingApplications: excludingApplications, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)

        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            try await stream.startCapture()
            self.stream = stream
        } catch {
            Task { @MainActor in self.presenter?.showError("Failed to start capture: \(error.localizedDescription)") }
        }
    }

    // SCStreamOutput: Handle incoming frames
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer), self.stream != nil, !isTearingDown else { return }
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        }
    }

    // SCStreamDelegate: Handle stream errors
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            presenter?.showError("Screen capture stopped: \(error.localizedDescription)")
            // Trigger the standard close and cleanup procedure.
            self.close()
        }
    }
    
    // NSWindowDelegate: The primary cleanup hook for the window.
    func windowWillClose(_ notification: Notification) {
        // Prevent cleanup logic from running multiple times.
        if isTearingDown { return }
        isTearingDown = true

        // Immediately stop rendering.
        displayLayer.removeFromSuperlayer()
        displayLayer.flushAndRemoveImage()

        // Safely and asynchronously stop the ScreenCaptureKit stream.
        // The Task will retain 'self' until the stream has stopped.
        if let stream = self.stream {
            Task {
                do {
                    try await stream.stopCapture()
                } catch {
                    print("Error stopping capture: \(error.localizedDescription)")
                }
            }
            self.stream = nil
        }
        
        // Notify the presenter to update the app state.
        presenter?.mirrorWindowClosedByUser()
    }
}

// MARK: - Presenter (App logic for SwiftUI)

@MainActor
final class Presenter: ObservableObject {
    private var model = AppState()
    private var selectionOverlay: SelectionOverlayWindow?
    private var mirrorWindow: MirrorWindow?

    func startSelection() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
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
                guard let scDisplay = content.displays.first(where: { $0.displayID == screen.displayID }) else {
                    showError("Could not find a matching display to capture.")
                    return
                }
                
                let myBundleID = Bundle.main.bundleIdentifier
                let excludedApps = content.applications.filter { $0.bundleIdentifier == myBundleID }

                self.mirrorWindow?.close()
                let mirror = MirrorWindow(contentRect: region, presenter: self)
                self.mirrorWindow = mirror
                await mirror.startCapture(for: scDisplay, on: screen, region: region, excludingApplications: excludedApps)

                self.model.isCapturing = true
            } catch {
                showError("""
                Failed to start mirroring: \(error.localizedDescription)
                If you just enabled Screen Recording permissions, you may need to quit and relaunch RegionMirror.
                """)
            }
        }
    }

    func stopCapture() {
        // Programmatically close the window.
        // Cleanup is handled by the windowWillClose delegate method.
        mirrorWindow?.close()
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

    // This is called by MirrorWindow's `windowWillClose` delegate method.
    func mirrorWindowClosedByUser() {
        mirrorWindow = nil
        model.isCapturing = false
    }
    
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
