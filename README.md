# PickleRef POC — Phone-Based Pickleball Line-Calling Referee (iOS 15+)

Proof-of-concept iOS app that uses a single iPhone camera to detect pickleball
bounces near court lines and make IN/OUT calls, with a replay buffer.

**This is a POC**: it validates the CV pipeline (capture → ball tracking →
homography → bounce localization → line call). Accuracy on borderline calls is
expected to be in the ~3–5 cm error band discussed in the feasibility study.
It ships with an honest "no call" path.

## Architecture

```
CameraService (AVCaptureSession, 1080p@120/240fps where supported)
      │  CVPixelBuffer frames + timestamps
      ▼
BallTracker (color-segmentation ball detector + constant-velocity Kalman-ish
             tracker, sub-pixel centroid, motion-blur aware)
      │  BallObservation {t, imagePoint, confidence}
      ▼
CourtCalibration (4-corner tap homography: image → court plane, feet)
      │  Homography H (3x3, DLT + normalization)
      ▼
BounceDetector (vertical-velocity sign flip + trajectory arc fit around
                occlusion gaps)
      │  BounceEvent {t, courtPoint, confidence}
      ▼
LineCallEngine (distance to nearest line vs ball radius; confidence tiers:
                IN / OUT / TOO_CLOSE)
      │
      ▼
ReplayBuffer (ring buffer of recent frames → slow-mo replay clip on call)
      │
      ▼
RefereeViewModel → SwiftUI UI (live preview, calls list, calibration screen)
```

## Files

| Path | Purpose |
|---|---|
| `App/PickleRefApp.swift` | App entry point |
| `App/RefereeViewModel.swift` | Orchestrates pipeline + UI state |
| `Camera/CameraService.swift` | AVCapture high-fps capture, ring buffer hooks |
| `Camera/FrameRingBuffer.swift` | Bounded frame history for replay + arc fitting |
| `Vision/BallDetector.swift` | Color/contrast ball segmentation (v1: no ML model) |
| `Vision/BallTracker.swift` | Temporal tracker + occlusion handling |
| `Court/CourtGeometry.swift` | Official court dimensions in feet |
| `Court/Homography.swift` | DLT homography + point mapping |
| `Court/CalibrationView.swift` | Tap 4 court corners to calibrate |
| `Engine/BounceDetector.swift` | Bounce event detection via arc fitting |
| `Engine/LineCallEngine.swift` | In/out decision + confidence tiers |
| `Engine/ReplayBuffer.swift` | Frame clips for replay |
| `UI/RefereeView.swift` | Main HUD, calls list |
| `Support/MathUtils.swift` | Small matrix helpers |

## Why color segmentation instead of an ML model for v1?

A POC must run at 120–240 fps on-device with zero training data. A tuned
color/contrast detector for the (commonly yellow/green) pickleball, plus
trajectory physics, is enough to validate the pipeline end-to-end. Swapping in
a TrackNet-style or YOLO-nano detector later only replaces `BallDetector` —
the tracker, bounce detector, and call engine are detector-agnostic.

## Setup (macOS + Xcode required — POC source was authored on Windows)

1. Install Xcode 14+ on a Mac.
2. `xcodegen` route (recommended): install via `brew install xcodegen`, then
   run `xcodegen generate` in this folder (project spec included:
   `project.yml`).
3. Or manually: create a new iOS App project (SwiftUI, iOS 15+), then drag the
   `PickleRef/` source folder in.
4. Add `NSCameraUsageDescription` to Info.plist (xcodegen handles this).
5. Run on a **real device** — the simulator has no camera. Best results:
   iPhone with 120/240 fps support, mounted 6–10 ft high behind the baseline.

## Using the POC

1. Mount the phone behind one baseline, elevated, seeing the full court.
2. On the Calibrate tab, tap the four corners of the court (baseline corners
   and kitchen-line corners of the near half you want to officiate).
3. Use a **bright orange/green ball** and set its color in Settings (HSV
   range sliders).
4. Play. Calls appear as IN / OUT / TOO CLOSE with a replay clip.

## Known POC limitations

- No ML ball detector (color-based; struggles with courts/balls of similar hue).
- Homography from 4 corner taps assumes a planar court (true) but bounce
  localization uses the ball's image centroid, not its ground contact point —
  expect several cm of parallax error at low camera heights.
- Single camera: far-side kitchen-line occlusion is unsolved (see feasibility
  report); near-half officiating only.
- No multi-phone sync, no NVZ foot-fault logic yet.
