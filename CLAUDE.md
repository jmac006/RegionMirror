# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RegionMirror is a macOS SwiftUI utility that enables screen region sharing for video conferencing apps like Microsoft Teams. It creates a selectable screen region overlay and mirrors that region in a shareable window using ScreenCaptureKit.

## Project Goal: Crisp Screen Region Mirroring

The objective is to create a macOS utility that captures a user-selected portion of the screen and displays it in a separate window. **The core requirement is that the mirrored content must be perfectly crisp and pixel-perfect, especially on high-DPI (Retina) displays, while remaining usable for screen sharing.**

### Initial Problem Statement
The mirrored window appears crisp on a standard (non-Retina) ultrawide monitor but is blurry and soft on a MacBook Pro's Retina display.

### Summary of Troubleshooting Steps

Here is a chronological summary of the solutions that have been implemented and their outcomes:

**1. Initial Attempts (Pre-Troubleshooting)**
- What: The initial code used ScreenCaptureKit and an AVSampleBufferDisplayLayer with .nearest neighbor filtering. Logic was in place to match window points to buffer pixels.
- Result: Blurry output on Retina displays. This confirmed that a simple 1:1 point-to-pixel mapping was being subverted by the rendering pipeline.

**2. Solution Attempt #1: Disable Implicit Scaling**
- Hypothesis: ScreenCaptureKit might be performing its own scaling, causing the initial blur.
- Action: We set `cfg.scalesToFit = false` in the SCStreamConfiguration.
- Result: No visible change. The output remained blurry, indicating the scaling issue was happening later in the pipeline (within AppKit/Core Animation).

**3. Solution Attempt #2: Isolate the Display Layer**
- Hypothesis: Placing the AVSampleBufferDisplayLayer inside the default contentView's layer hierarchy was causing unforeseen scaling conflicts.
- Action: We created a custom NSView subclass (MirroredContentView) that used the AVSampleBufferDisplayLayer as its primary backing layer (makeBackingLayer()).
- Result: Introduced a severe bug where the window's backing store was exactly 2x the size of the incoming video buffer, causing extreme blurriness. However, it revealed the core problem: a size mismatch between the buffer and the final rendered surface.

**4. Solution Attempt #3: Core Animation Transform**
- Hypothesis: Instead of resizing the layer, we should resize the window and use a CATransform3DMakeScale to perform a "dumb" pixel-doubling scale on the layer.
- Action: We sized the window to be visually correct (2x the points) and applied a CATransform3D to the displayLayer.
- Result: Partial success and a new bug. The content became crisp but was rendered in the bottom-left corner of a much larger window. This proved that integer-multiple scaling is the key to crispness, but that CALayer's layout behavior with transforms is complex and unreliable for this use case.

**5. Solution Attempt #4: Switch to a Full Metal Rendering Pipeline**
- Hypothesis: The AppKit/Core Animation layout system is the source of our problems. We must bypass it entirely and take direct control of the GPU rendering.
- Action: We replaced the AVSampleBufferDisplayLayer with a MTKView and wrote a basic Metal pipeline to render the incoming frame.
- Result: A new, severe bug. The output was a heavily distorted and tiled/repeating image. This revealed two critical misunderstandings:
  - The video data was not BGRA but YCbCr (a multi-planar video format).
  - The texture sampler's default "repeat" behavior was causing tiling.

**6. Solution Attempt #5: Advanced Metal Pipeline (YCbCr Handling)**
- Hypothesis: We must correctly handle the YCbCr pixel format and fix the texture sampling.
- Action:
  - Rewrote the Metal pipeline to handle multi-planar video by creating two textures (one for Luma, one for Chroma).
  - Wrote a new fragment shader to perform the YCbCr-to-RGB color conversion on the GPU.
  - Replaced the "full-screen triangle" with a proper 4-vertex quad to fix texture coordinates.
  - Set the sampler's address mode to .clampToEdge to prevent tiling.
- Result: Partial Success. The color distortion and tiling artifacts were completely fixed. The output is now correctly colored and positioned. However, the image is blurry again, similar to the very first problem.

**7. Solution Attempt #6: Disable Mipmapping in Metal**
- Hypothesis: The final source of blurriness in the Metal pipeline is the GPU's default mipmapping behavior, which performs filtering even when scaling isn't happening.
- Action: We explicitly set the mipFilter on the MTLSamplerDescriptor to .notMipmapped.
- Result: No visible change. The output remains blurry. This is a very surprising result, as it indicates the blur is not from mipmapping.

### Current Implementation Notes

The current codebase uses the AVSampleBufferDisplayLayer approach with careful pixel alignment and scaling management. When working on display quality issues, be aware of these key factors:
- Retina display scaling complications
- ScreenCaptureKit coordinate system differences  
- Core Animation layer scaling behavior
- The importance of integer pixel boundaries for crispness

## Build and Development Commands

This is an Xcode project that requires Apple's development tools:

- **Build**: Use Xcode to build the project (Product → Build or Cmd+B)
- **Run**: Use Xcode to run the project (Product → Run or Cmd+R)  
- **Test**: Use Xcode to run tests (Product → Test or Cmd+U)
- **Command line build**: `xcodebuild -project RegionMirror.xcodeproj -scheme RegionMirror build`
- **Command line test**: `xcodebuild test -project RegionMirror.xcodeproj -scheme RegionMirror -destination 'platform=macOS'`

Note: Building with swiftc alone is not supported for this multi-file SwiftUI project.

## Architecture

### Core Components

- **RegionMirrorApp.swift**: SwiftUI app entry point with basic WindowGroup
- **ContentView.swift**: Simple UI with "Start Selection" button that triggers the region selection process
- **RegionMirrorEngine.swift**: Contains the main application logic with several key classes:

### Key Classes in RegionMirrorEngine

1. **Presenter**: `@MainActor ObservableObject` that manages the app state and coordinates between UI and capture components
2. **SelectionOverlayWindow**: Creates a Cmd+Shift+5 style overlay for region selection with mouse tracking
3. **MirrorWindow**: The shareable window that displays the captured region using ScreenCaptureKit (`SCStream`)
4. **BorderOverlayWindow**: Shows a dashed blue border around the selected region during capture

### Technical Architecture

- **Pixel-perfect capture**: Uses device pixel snapping and coordinate conversion to ensure crisp 1:1 pixel mapping
- **Multi-display support**: Handles different scale factors and pixel densities across displays
- **Screen Recording permissions**: Uses `CGPreflightScreenCaptureAccess()` and `CGRequestScreenCaptureAccess()`
- **Framework dependencies**: AppKit, ScreenCaptureKit, AVFoundation, QuartzCore, CoreGraphics

### Key Technical Details

- Region selection snaps to device pixels for crisp rendering
- ScreenCaptureKit captures with integer pixel coordinates  
- Mirror window size is calculated as pixels ÷ scale factor
- Uses `.nearest` mag/min filters to prevent scaling blur
- Excludes the RegionMirror app itself from capture to prevent recursion

## Requirements

- macOS 12.3+ (ScreenCaptureKit requirement)
- macOS 15.0+ deployment target (set in project configuration)
- Screen Recording permission required
- Xcode 16.4+ for building

## Bundle Configuration

- Bundle identifier: `Mac-Motion.RegionMirror`
- App sandbox enabled with read-only file access
- No entitlements for ScreenCaptureKit (uses system permission dialog)

## Testing Structure

- **RegionMirrorTests**: Unit test target (may be empty)
- **RegionMirrorUITests**: UI test target with launch tests

## Development Notes

- Use Xcode for all development as this is a standard macOS app project
- The app manages window lifecycles manually to prevent premature release
- ScreenCaptureKit streams are properly torn down in `windowWillClose`
- Error handling includes permission troubleshooting guidance