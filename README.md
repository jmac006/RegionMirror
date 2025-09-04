# RegionMirror

## Description
RegionMirror is a small macOS utility that lets you draw a rectangle on your screen and opens a **shareable app window** that mirrors exactly that region. In Microsoft Teams (and other meeting apps) you can then select this RegionMirror window via **Share → Window**, so you only share the focused area instead of your entire display.

Unlike system-level “share portion of screen” features, RegionMirror gives you a real window you can see and position anywhere, making it obvious what your audience is seeing.

## What it does
- Shows a simple control UI with a **Start Selection** button.
- Displays a Cmd+Shift+5–style overlay so you can **click-and-drag** to define the region.
- Opens a normal macOS window named **RegionMirror** that mirrors only the selected rectangle.
- The mirror is **pixel-perfect and Retina-crisp**: one captured pixel maps to one device pixel (no scaling blur).
- The mirror window is **minimizable** and resizable (resizes snap to device-pixel increments to preserve sharpness).

## Requirements
- **macOS 12.3+** (ScreenCaptureKit is required; works through macOS 15/Sequoia).
- Apple Silicon or Intel (tested on Apple Silicon; see “Tested” below).
- App needs **Screen Recording** permission (see “Permissions” and “Troubleshooting”).

## Library dependencies
No third-party packages. Uses Apple frameworks shipped with macOS:
- `AppKit`
- `ScreenCaptureKit`
- `AVFoundation`
- `QuartzCore`
- `CoreGraphics`

## Installation

### Xcode (recommended)
1. Clone or download the repository.
2. Open `RegionMirror.xcodeproj` in Xcode.
3. In **Signing & Capabilities**, set a valid team (any free Developer ID is fine for local runs).
4. Select the **RegionMirror** scheme and press **Run**.



# Launch the app
open build/Build/Products/Release/RegionMirror.app

Note: Building with swiftc alone is not supported for the multi-file SwiftUI project. Use Xcode or xcodebuild.

Usage
	1.	Launch RegionMirror.
	2.	Click Start Selection.
	3.	Drag to select the area you want to share.
	4.	A window named RegionMirror appears showing only that region.
	5.	In Microsoft Teams: Share → Window → RegionMirror.
	6.	To stop, close the RegionMirror window or quit the app.

Permissions

RegionMirror uses ScreenCaptureKit and requires screen recording access.
	•	Go to System Settings → Privacy & Security → Screen Recording.
	•	On newer macOS versions (Sequoia), the toggle may appear as Screen & System Audio Recording.
	•	Ensure RegionMirror is enabled.
	•	If you just changed the setting, quit and relaunch the app so macOS updates its TCC database.

You can also open the Settings pane via these URLs:
	•	x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture
	•	x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording

Why the mirror is crisp
	•	The selection is snapped to device-pixel boundaries.
	•	The capture sourceRect uses integer pixel coordinates.
	•	The mirror window is sized to pixels ÷ scale (so 1 captured pixel = 1 device pixel).
	•	The preview layer uses .nearest min/mag filters and is backing-aligned to the pixel grid.
	•	Resize increments are set to 1 / scale to avoid half-pixel sizes.

Limitations
	•	Does not create a true “virtual display.” It presents a normal app window that you choose in Teams.
	•	If the mirror window overlaps the captured area, you may see a recursive “hall of mirrors.” Move the window away or to another Space/display.
	•	Audio is not captured or mixed; this app is for visual mirroring only.
	•	If you manually resize the mirror window to non-integer pixel sizes, crispness may degrade. The app snaps increments to device pixels to minimize this, but extreme sizes can still scale content.
	•	Some macOS updates change the label or behavior of the Screen Recording privacy pane; you may need to relaunch after toggling.

Troubleshooting

I already enabled the permission but still get a warning.
	•	Fully quit the app (and Xcode, if running from Xcode) and relaunch.
	•	Check both panes if present: Screen Recording and Screen & System Audio Recording.
	•	Ensure your bundle identifier is stable (changing it creates a “new” app in TCC).

Reset the permission for this app
# Replace the bundle ID with your target’s bundle identifier
tccutil reset ScreenCapture com.yourcompany.RegionMirror

Then launch RegionMirror again and re-grant access when prompted.

The mirror looks blurry.
	•	Re-select the region and avoid resizing the window arbitrarily.
	•	Ensure the mirror hasn’t been dragged to a display with a different scale mid-session. If it has, reselect the region or relaunch the app.
	•	Verify the Teams share is the RegionMirror window (not the entire screen scaled by the meeting app).

Tested
- Hardware: Apple Silicon M2 Max
- macOS: Sequoia 15.6.1
- Apps: Microsoft Teams (window sharing), also verified with other conferencing apps that support window-level sharing.

RegionMirror/
├─ RegionMirror.xcodeproj
├─ RegionMirror/                 # Source
│  ├─ RegionMirrorApp.swift      # SwiftUI app entry
│  ├─ ContentView.swift          # Simple UI with Start Selection
│  └─ RegionMirrorEngine.swift   # Selection overlay + ScreenCaptureKit mirror (crisp)
└─ RegionMirrorTests/            # Optional test target (may be empty)
