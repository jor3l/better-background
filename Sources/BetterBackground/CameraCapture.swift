import AVFoundation
import CoreVideo

struct CameraInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Wraps AVCaptureSession and hands BGRA frames to `onFrame` on a background queue.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "bb.camera.session")
    private let videoQueue = DispatchQueue(label: "bb.camera.video", qos: .userInteractive)
    private var currentInput: AVCaptureDeviceInput?

    var onFrame: ((CVPixelBuffer) -> Void)?

    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    func start(deviceID: String?, resolution: CaptureResolution = .p720, completion: @escaping (String?) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                completion("Camera access was denied. Allow it in System Settings > Privacy & Security > Camera.")
                return
            }
            self.sessionQueue.async {
                let error = self.configure(deviceID: deviceID, resolution: resolution)
                if error == nil, !self.session.isRunning {
                    self.session.startRunning()
                }
                completion(error)
            }
        }
    }

    private func configure(deviceID: String?, resolution: CaptureResolution) -> String? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let input = currentInput {
            session.removeInput(input)
            currentInput = nil
        }
        let devices = Self.availableDevices()
        let chosen = devices.first(where: { $0.uniqueID == deviceID })
            ?? AVCaptureDevice.default(for: .video)
            ?? devices.first
        guard let device = chosen else { return "No camera found." }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return "Can't use \(device.localizedName)." }
            session.addInput(input)
            currentInput = input
        } catch {
            return error.localizedDescription
        }

        let preset: AVCaptureSession.Preset = resolution == .p1080 ? .hd1920x1080 : .hd1280x720
        if session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(output) else { return "Can't read frames from the camera." }
            session.addOutput(output)
        }
        return nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
