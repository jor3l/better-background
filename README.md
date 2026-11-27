# BetterBackground

A macOS app (Apple Silicon, macOS 15+) that puts you inside a lit 3D scene from your webcam, for video calls and streaming.

## The camera playground

The app is a playground for testing the product and tuning it live:

- **Preview** on the left, switchable between the final composite, the raw camera, the Vision person mask and the depth map, with an optional stats overlay (fps, model time, how much of the frame is you) and a pause button.
- **Settings** on the right, in six panels. Every change shows up immediately:
  - **Scene**: pick an environment (living room, dark studio, neon den, bright office), change its wall, floor and accent colours, and toggle props and the desk.
  - **Light**: key light intensity, direction, height, colour temperature and shadows; rim light colour and intensity; front fill and environment light.
  - **Person**: cutout on/off, mask quality and threshold, edge cut, depth strength and smoothing, size and position in the room, and how much of the original camera light is kept.
  - **Camera**: device, resolution, mirror and flip.
  - **View**: virtual camera field of view, height, distance and sway. You can also drag the preview to move it.
  - **Presets**: save the current settings under a name, load or delete presets, or reset everything.
- Settings are saved automatically and restored on the next launch.

Under the hood: [Depth Anything V2 Small](https://huggingface.co/apple/coreml-depth-anything-v2-small) (Apple's Core ML conversion) and Apple Vision person segmentation run on every frame. You are drawn as a depth-displaced surface in a RealityKit room, so the scene's lights shade you and the camera shows a little parallax. Only open-source models and Apple frameworks are used.

## Getting the app

You don't need to build anything locally. Every push runs the **Build** workflow on a GitHub macOS runner:

1. Open the [Actions tab](../../actions/workflows/build.yml), pick the latest run and download **BetterBackground-dmg**.
2. Open the `.dmg` and drag BetterBackground to Applications.
3. The app is ad-hoc signed (no Apple Developer account), so macOS blocks the first launch. Either open **System Settings > Privacy & Security** and click **Open Anyway**, or run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/BetterBackground.app
   ```

Tagging a commit `v*` also attaches the `.dmg` to a GitHub Release.

## How the build works

- `scripts/fetch_model.py` downloads `DepthAnythingV2SmallF16.mlpackage` from Hugging Face (cached between runs). No weights are stored in git.
- `xcrun coremlcompiler` compiles it into the app bundle.
- `scripts/package_app.sh` builds the Swift package, assembles `BetterBackground.app`, signs it ad-hoc and makes the `.dmg`.

## Tips

- If you look inside-out (nose pushed back), turn on **Person > Invert depth**.
- If the image is upside down, toggle **Camera > Flip vertically**.
- Use the **Mask** preview to tune the mask threshold, and the **Depth** preview to check the depth map.
