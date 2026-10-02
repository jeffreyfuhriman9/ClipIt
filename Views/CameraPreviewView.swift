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

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}
