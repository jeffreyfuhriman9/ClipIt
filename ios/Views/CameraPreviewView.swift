import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var cameraManager: CameraManager
    var onLayerReady: ((AVCaptureVideoPreviewLayer) -> Void)? = nil

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        
        // Attach preview layer on main thread, but start capture session off the main thread
        cameraManager.attachPreviewLayer(view.previewLayer)
        onLayerReady?(view.previewLayer)
        
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // Only attach or start if session was disconnected to prevent redundant main-thread work
        if uiView.previewLayer.session == nil {
            cameraManager.attachPreviewLayer(uiView.previewLayer)
        }
    }

    static func dismantleUIView(_ uiView: PreviewUIView, coordinator: ()) {
        uiView.previewLayer.session = nil
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The capture layer has no image until its first camera frame arrives.
        // Keep that startup gap black instead of exposing the host view's
        // default light background.
        backgroundColor = .black
        previewLayer.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}
