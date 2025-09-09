//
//  RegionMirrorEngine.swift
//  RegionMirror
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
    /// Pixel scale factors (pixels per point) derived from CoreGraphics for this screen.
    /// More robust than `backingScaleFactor` when different displays are attached.
    var pixelScale: (sx: CGFloat, sy: CGFloat) {
        let did = self.displayID
        let pw = CGFloat(CGDisplayPixelsWide(did))
        let ph = CGFloat(CGDisplayPixelsHigh(did))
        // `frame` is in points
        let sw = self.frame.width
        let sh = self.frame.height
        let sx = pw / max(sw, 1)
        let sy = ph / max(sh, 1)
        return (sx, sy)
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
    /// Snap a rect in *points* with separate X/Y pixel scales.
    func snappedToDevicePixels(scaleX: CGFloat, scaleY: CGFloat) -> CGRect {
        let x = round(self.origin.x * scaleX) / scaleX
        let y = round(self.origin.y * scaleY) / scaleY
        let w = round(self.size.width * scaleX) / scaleX
        let h = round(self.size.height * scaleY) / scaleY
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
    private let targetScaleX: CGFloat
    private let targetScaleY: CGFloat
    var onSelectionComplete: ((CGRect) -> Void)?

    init(on screen: NSScreen) {
        self.targetScale = screen.backingScaleFactor
        let s = screen.pixelScale
        self.targetScaleX = s.sx
        self.targetScaleY = s.sy
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.25) // visible & receives events
        ignoresMouseEvents = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = false
        isReleasedWhenClosed = false // Manage lifecycle manually

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
            rect = rect.snappedToDevicePixels(scaleX: targetScaleX, scaleY: targetScaleY)
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
    private var capturePixelSize: CGSize = .zero  // Store the actual capture dimensions

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

        // Preview layer - configured for pixel-perfect rendering
        displayLayer.isOpaque = true
        displayLayer.videoGravity = .resize  // Critical: .resize for exact pixel mapping
        displayLayer.magnificationFilter = .nearest
        displayLayer.minificationFilter = .nearest
        displayLayer.allowsEdgeAntialiasing = false
        displayLayer.shouldRasterize = false
        displayLayer.drawsAsynchronously = false  // Force synchronous drawing
        displayLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)  // Center anchoring
        contentView!.layer?.addSublayer(displayLayer)

        // Initial alignment & scale
        applyScaleFromCurrentScreen()

        // Keep alignment on resize
        contentView?.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
            guard let self = self, let cv = self.contentView else { return }
            // Maintain pixel-exact layer sizing on resize
            if self.capturePixelSize != .zero {
                self.displayLayer.bounds = CGRect(origin: .zero, size: self.capturePixelSize)
                self.displayLayer.position = CGPoint(x: cv.bounds.midX, y: cv.bounds.midY)
            }
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
        
        // Critical: Set contentView layer scale for proper backing store
        contentView?.layer?.contentsScale = s
        
        // Key insight: Size displayLayer in PIXELS, set contentsScale to 1.0
        // This forces 1:1 pixel mapping without interpolation
        displayLayer.contentsScale = 1.0
        
        if let cv = contentView, capturePixelSize != .zero {
            // Size displayLayer bounds to match capture pixel dimensions exactly
            // This prevents any scaling/interpolation of the video content
            displayLayer.bounds = CGRect(origin: .zero, size: capturePixelSize)
            displayLayer.position = CGPoint(x: cv.bounds.midX, y: cv.bounds.midY)
        }
        
        // Ensure minimum resize increments to prevent crashes
        let minIncrement: CGFloat = 1.0
        let increment = max(minIncrement, 1 / s)
        contentResizeIncrements = NSSize(width: increment, height: increment)
    }

    @MainActor
    func startCapture(for scDisplay: SCDisplay, on screen: NSScreen, region: CGRect, excludingApplications: [SCRunningApplication]) async {
        let (sx, sy) = screen.pixelScale

        // Convert the selection (points) to integer pixels relative to the display,
        // flipping Y because ScreenCaptureKit uses a top-left origin in pixel space.
        let x_px = Int(round(region.origin.x * sx))
        let y_px = Int(round((screen.frame.height - region.origin.y - region.height) * sy))
        let w_px = max(16, Int(round(region.size.width * sx)))
        let h_px = max(16, Int(round(region.size.height * sy)))
        let pixelRect = CGRect(x: x_px, y: y_px, width: w_px, height: h_px)

        // Store the capture pixel dimensions for exact layer sizing
        self.capturePixelSize = CGSize(width: w_px, height: h_px)
        
        // Size the window to the ORIGINAL region size in points
        let sizePoints = NSSize(width: region.size.width, height: region.size.height)
        
        self.setContentSize(sizePoints)
        self.contentAspectRatio = sizePoints
        
        // Set resize increments to maintain pixel boundaries
        let currentScale = self.screen?.backingScaleFactor ?? 2.0
        self.contentResizeIncrements = NSSize(width: 1 / currentScale, height: 1 / currentScale)
        self.applyScaleFromCurrentScreen()

        let cfg = SCStreamConfiguration()
        cfg.width  = w_px
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
        guard outputType == .screen, !isTearingDown, CMSampleBufferIsValid(sampleBuffer), self.stream != nil else { return }
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        }
    }

    // SCStreamDelegate: Handle stream errors
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            presenter?.showError("Screen capture stopped: \(error.localizedDescription)")
            self.close()
        }
    }
    
    // NSWindowDelegate: The primary cleanup hook for the window.
    func windowWillClose(_ notification: Notification) {
        if isTearingDown { return }
        isTearingDown = true

        displayLayer.flushAndRemoveImage()
        displayLayer.removeFromSuperlayer()

        if let stream = self.stream {
            Task {
                do {
                    // **FIX 2**: First, remove self as an output to stop receiving frames immediately.
                    try stream.removeStreamOutput(self, type: .screen)
                    // Then, asynchronously stop the capture process.
                    try await stream.stopCapture()
                } catch {
                    print("Error during stream teardown: \(error.localizedDescription)")
                }
            }
            self.stream = nil
        }
        
        presenter?.mirrorWindowClosedByUser()
    }
}

// MARK: - Sharing Border Overlay

final class BorderOverlayWindow: NSWindow {
    private let borderLayer = CAShapeLayer()

    init(region: CGRect) {
        super.init(contentRect: region, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        level = .floating
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false // Manage lifecycle manually

        let view = NSView(frame: .zero)
        view.wantsLayer = true
        contentView = view

        borderLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        borderLayer.lineWidth = 4.0
        borderLayer.fillColor = nil
        borderLayer.lineDashPattern = [15, 10]
        borderLayer.path = CGPath(rect: view.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        borderLayer.frame = view.bounds
        view.layer?.addSublayer(borderLayer)

        let animation = CABasicAnimation(keyPath: "lineDashPhase")
        animation.fromValue = 0
        animation.toValue = borderLayer.lineDashPattern?.map { $0.doubleValue }.reduce(0, +) ?? 0
        animation.duration = 0.75
        animation.repeatCount = .infinity
        borderLayer.add(animation, forKey: "lineDashPhaseAnimation")
    }
}


// MARK: - Presenter (App logic for SwiftUI)

@MainActor
final class Presenter: ObservableObject {
    private var model = AppState()
    private var selectionOverlay: SelectionOverlayWindow?
    private var mirrorWindow: MirrorWindow?
    private var borderOverlay: BorderOverlayWindow?


    func startSelection() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        // **FIX 1**: If a selection is already in progress, close it before starting a new one.
        selectionOverlay?.close()
        selectionOverlay = nil

        let targetScreen = NSScreen.screenUnderMouse()
        let overlay = SelectionOverlayWindow(on: targetScreen)
        overlay.onSelectionComplete = { [weak self] rect in
            guard let self = self else { return }
            self.model.selectedRegion = rect
            self.startMirroring(on: targetScreen, region: rect)
            self.selectionOverlay = nil // Clean up reference after completion
        }
        self.selectionOverlay = overlay
        
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
                self.borderOverlay?.close()

                let mirror = MirrorWindow(contentRect: region, presenter: self)
                self.mirrorWindow = mirror
                await mirror.startCapture(for: scDisplay, on: screen, region: region, excludingApplications: excludedApps)

                let border = BorderOverlayWindow(region: region)
                self.borderOverlay = border
                border.orderFront(nil)

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

    func mirrorWindowClosedByUser() {
        mirrorWindow = nil
        borderOverlay?.close()
        borderOverlay = nil
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
