# BetterBackground

A macOS app (Apple Silicon, macOS 15+) that puts you inside a lit 3D scene from your webcam, for video calls and streaming.

## Current state: depth and lighting proof of concept

- Live webcam capture (pick any camera, including Continuity Camera).
- [Depth Anything V2 Small](https://huggingface.co/apple/coreml-depth-anything-v2-small) (Apple's Core ML conversion) runs on every frame.
- Apple Vision person segmentation cuts you out of the frame.
- You are drawn as a depth-displaced surface in a simple RealityKit room with a warm spot light (casts shadows), a blue rim light and image-based environment light, so the scene's lights shade you and the camera shows a little parallax.
- A side panel has sliders for depth strength, smoothing, light direction, colour and intensity.

Only open-source models and Apple frameworks are used.

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

## Using the proof of concept

- If the person looks inside-out (nose pushed back), turn on **Invert depth**.
- If the image is upside down, toggle **Flip image vertically**.
- Drag on the 3D view to move the camera; **Camera sway** animates it.
- The overlay shows frame rate, model time and a small depth preview.
