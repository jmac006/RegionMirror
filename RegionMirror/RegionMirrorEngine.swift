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
    // Custom layer for pixel-perfect rendering
    private let imageLayer = CALayer()
    private var stream: SCStream?
    weak var presenter: Presenter?
    private var isTearingDown = false
    private var capturePixelSize: CGSize = .zero
    
    // Queue for frame processing
    private let frameQueue = DispatchQueue(label: "com.regionmirror.frameprocessing", qos: .userInteractive)
    
    init(contentRect: CGRect, presenter: Presenter) {
        self.presenter = presenter
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "RegionMirror"
        isReleasedWhenClosed = false
        delegate = self
        
        // Configure content view
        contentView?.wantsLayer = true
        contentView!.layer?.masksToBounds = true
        
        // Configure image layer for pixel-perfect rendering
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        imageLayer.shouldRasterize = false
        imageLayer.drawsAsynchronously = false
        imageLayer.isOpaque = true
        imageLayer.contentsGravity = .center // Don't stretch content
        
        // CRITICAL: Disable all edge antialiasing and interpolation
        imageLayer.allowsEdgeAntialiasing = false
        imageLayer.edgeAntialiasingMask = []
        
        contentView!.layer?.addSublayer(imageLayer)
        
        // Initial setup
        applyScaleFromCurrentScreen()
        
        // Handle resize events
        contentView?.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            self?.updateLayerFrame()
        }
        
        // Handle screen changes
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            self?.applyScaleFromCurrentScreen()
        }
        
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeBackingPropertiesNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            self?.applyScaleFromCurrentScreen()
        }
        
        center()
        makeKeyAndOrderFront(nil)
    }
    
    private func applyScaleFromCurrentScreen() {
        guard let screen = self.screen else { return }
        let scale = screen.backingScaleFactor
        
        // Set the content view's layer scale
        contentView?.layer?.contentsScale = scale
        
        // CRITICAL: Set imageLayer's contentsScale to match the screen
        // This ensures the CGImage is rendered at the correct resolution
        imageLayer.contentsScale = scale
        
        // Update resize increments
        contentResizeIncrements = NSSize(width: 1.0 / scale, height: 1.0 / scale)
        
        updateLayerFrame()
    }
    
    private func updateLayerFrame() {
        guard let contentView = self.contentView else { return }
        
        if capturePixelSize != .zero {
            // Get current screen scale
            let scale = self.screen?.backingScaleFactor ?? 2.0
            
            // Calculate the size in points that matches our pixel size
            let sizeInPoints = CGSize(
                width: capturePixelSize.width / scale,
                height: capturePixelSize.height / scale
            )
            
            // Center the layer in the content view
            let x = (contentView.bounds.width - sizeInPoints.width) / 2
            let y = (contentView.bounds.height - sizeInPoints.height) / 2
            
            imageLayer.frame = CGRect(origin: CGPoint(x: x, y: y), size: sizeInPoints)
        } else {
            imageLayer.frame = contentView.bounds
        }
    }

    @MainActor
    func startCapture(for scDisplay: SCDisplay, on screen: NSScreen, region: CGRect, excludingApplications: [SCRunningApplication]) async {
        // Get exact physical dimensions using Core Graphics directly
        let displayBounds = CGDisplayBounds(scDisplay.displayID)
        let displayMode = CGDisplayCopyDisplayMode(scDisplay.displayID)!
        let actualScaleFactor = Int(displayMode.pixelWidth) / Int(displayMode.width)
        
        print("Display info - logical: \(displayMode.width)×\(displayMode.height), physical: \(displayMode.pixelWidth)×\(displayMode.pixelHeight), scale: \(actualScaleFactor)")
        
        // Convert region to pixels using actual scale factor
        let x_px = Int(round(region.origin.x * CGFloat(actualScaleFactor)))
        let y_px = Int(round((screen.frame.height - region.origin.y - region.height) * CGFloat(actualScaleFactor)))
        let w_px = max(16, Int(round(region.size.width * CGFloat(actualScaleFactor))))
        let h_px = max(16, Int(round(region.size.height * CGFloat(actualScaleFactor))))
        let pixelRect = CGRect(x: x_px, y: y_px, width: w_px, height: h_px)
        
        self.capturePixelSize = CGSize(width: w_px, height: h_px)
        
        print("Capture config - region: \(region), pixels: \(w_px)×\(h_px), sourceRect: \(pixelRect)")
        
        // Size window to original region
        let sizePoints = NSSize(width: region.size.width, height: region.size.height)
        self.setContentSize(sizePoints)
        self.contentAspectRatio = sizePoints
        
        // Update layer positioning
        updateLayerFrame()
        
        // CRITICAL: Configure stream for pixel-perfect capture
        let cfg = SCStreamConfiguration()
        cfg.width = w_px
        cfg.height = h_px
        cfg.showsCursor = true
        cfg.sourceRect = pixelRect
        
        // KEY FIXES from Claude Opus analysis:
        cfg.captureResolution = .best  // Maximum quality
        cfg.scalesToFit = false  // CRITICAL: prevents automatic scaling
        cfg.preservesAspectRatio = true
        cfg.pixelFormat = kCVPixelFormatType_32BGRA  // Maximum quality
        
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)  // 60 FPS
        cfg.queueDepth = 5  // Optimal for real-time capture
        
        let filter = SCContentFilter(display: scDisplay, excludingApplications: excludingApplications, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        
        do {
            // Use background queue for frame processing
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
            try await stream.startCapture()
            self.stream = stream
            print("Stream started successfully with \(w_px)×\(h_px) capture resolution")
        } catch {
            Task { @MainActor in
                self.presenter?.showError("Failed to start capture: \(error.localizedDescription)")
            }
        }
    }

    // SCStreamOutput: Convert CMSampleBuffer to CGImage for pixel-perfect rendering
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              !isTearingDown,
              CMSampleBufferIsValid(sampleBuffer),
              self.stream != nil else { return }
        
        // Extract CVPixelBuffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // Lock the pixel buffer
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        // Verify pixel-perfect capture dimensions
        var frameCount = 0
        frameCount += 1
        if frameCount == 1 {
            print("First frame received - buffer: \(width)×\(height), expected: \(Int(capturePixelSize.width))×\(Int(capturePixelSize.height))")
            
            // Check frame metadata for scale factor verification
            if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
               let attachments = attachmentsArray.first {
                print("Frame metadata: \(attachments)")
            }
        }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        
        // Create CGImage directly from pixel buffer
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return }
        
        guard let cgImage = context.makeImage() else { return }
        
        // Update layer on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isTearingDown else { return }
            
            // CRITICAL: Disable implicit animations for immediate update
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            
            // Set the image directly - CALayer will handle proper scaling
            self.imageLayer.contents = cgImage
            
            CATransaction.commit()
        }
    }

    // SCStreamDelegate: Handle stream errors
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            presenter?.showError("Screen capture stopped: \(error.localizedDescription)")
            self.close()
        }
    }
    
    // NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        if isTearingDown { return }
        isTearingDown = true
        
        imageLayer.contents = nil
        imageLayer.removeFromSuperlayer()
        
        if let stream = self.stream {
            Task {
                do {
                    try stream.removeStreamOutput(self, type: .screen)
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
