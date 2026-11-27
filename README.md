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

You don't need to build anything locally. Every push to `main` runs the **Build** workflow on a GitHub macOS runner and publishes a new [Release](../../releases/latest):

1. Download `BetterBackground.dmg` from the [latest release](../../releases/latest).
2. Open the `.dmg` and drag BetterBackground to Applications.
3. The app is ad-hoc signed (no Apple Developer account), so macOS blocks the first launch. Either open **System Settings > Privacy & Security** and click **Open Anyway**, or run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/BetterBackground.app
   ```

After that the app updates itself: it checks the latest release once a day, and **BetterBackground > Check for Updates…** checks right away. **Settings > Updates** turns automatic checks and automatic installs on or off. Updates are downloaded by the app, so they don't need **Open Anyway** again.

Builds of pull requests are only uploaded as workflow artifacts (**BetterBackground-dmg** on the run's page).

## Releases and versioning

Each successful build of `main` is tagged `vX.Y.Z` and released automatically. The version bumps from the last release based on the commit messages since then ([Conventional Commits](https://www.conventionalcommits.org) style):

| Commits since the last release contain | Bump |
| --- | --- |
| `feat!:`, `fix!:` or `BREAKING CHANGE` | major (minor while the version is 0.x) |
| `feat:` / `feat(scope):` | minor |
| anything else | patch |

The first release is `0.1.0`. To force a bump, run the **Build** workflow by hand on `main` and pick `patch`, `minor` or `major`.

### Update signing

Updates use [Sparkle](https://sparkle-project.org) with an EdDSA (Ed25519) signature, which needs no Apple Developer account. The public key is `SUPublicEDKey` in `Resources/Info.plist`. The private key is the `SPARKLE_PRIVATE_KEY` repository secret (base64 of the 32-byte key seed). Each release gets an `appcast.xml` signed with it, and the app reads `releases/latest/download/appcast.xml`. Without the secret, releases still publish the `.dmg` but no appcast, so installed apps are not offered them.

To replace the key pair, run `scripts/make_appcast.py --generate-key` (needs `pip install cryptography`), put the private key in the secret and the public key in `Info.plist`. Apps already installed only trust the old key, so they will need one manual download.

## How the build works

- `scripts/fetch_model.py` downloads `DepthAnythingV2SmallF16.mlpackage` from Hugging Face (cached between runs). No weights are stored in git.
- `xcrun coremlcompiler` compiles it into the app bundle.
- `scripts/next_version.sh` works out the version from tags and commit messages.
- `scripts/package_app.sh` builds the Swift package, embeds Sparkle, assembles `BetterBackground.app`, signs it ad-hoc and makes the `.dmg`.
- `scripts/make_appcast.py` signs the `.dmg` and writes the release's `appcast.xml`.

## Using the proof of concept

- If the person looks inside-out (nose pushed back), turn on **Invert depth**.
- If the image is upside down, toggle **Flip image vertically**.
- Drag on the 3D view to move the camera; **Camera sway** animates it.
- The overlay shows frame rate, model time and a small depth preview.
