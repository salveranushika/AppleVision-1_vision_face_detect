import UIKit
import AVFoundation
import Vision

class ViewController: UIViewController {

    // Main view for showing camera content.
    @IBOutlet weak var previewView: UIView?
    @IBOutlet weak var gazeDirectionSlider: UISlider!
    
    // AVCapture variables
    var session: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    
    var videoDataOutput: AVCaptureVideoDataOutput?
    var videoDataOutputQueue: DispatchQueue?
    
    var captureDevice: AVCaptureDevice?
    var captureDeviceResolution: CGSize = CGSize()
    
    // Layer UI for drawing Vision results
    var rootLayer: CALayer?
    var detectionOverlayLayer: CALayer?
    var detectedFaceRectangleShapeLayer: CAShapeLayer?
    var detectedFaceLandmarksShapeLayer: CAShapeLayer?
    
    // Vision requests
    private var detectionRequests: [VNDetectFaceRectanglesRequest]?
    private var trackingRequests: [VNTrackObjectRequest]?
    
    lazy var sequenceRequestHandler = VNSequenceRequestHandler()
    
    // Blink and Gaze Properties
    var leftEyeX: (min: Float, max: Float) = (Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
    var leftEyeY: (min: Float, max: Float) = (Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
    var isBlinking = false
    
    // MARK: - UIViewController overrides
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Start the capture session setup on a background thread
        DispatchQueue.global(qos: .userInitiated).async {
            self.session = self.setupAVCaptureSession()
            self.session?.startRunning()
            
            // Ensure UI updates are on the main thread
            DispatchQueue.main.async {
                self.prepareVisionRequest()
                self.gazeDirectionSlider.minimumValue = 0
                self.gazeDirectionSlider.maximumValue = 1
            }
        }
    }
    
    // MARK: - AVCaptureSession setup
    
    fileprivate func setupAVCaptureSession() -> AVCaptureSession? {
        let captureSession = AVCaptureSession()
        
        do {
            let inputDevice = try self.configureFrontCamera(for: captureSession)
            self.configureVideoDataOutput(for: inputDevice.device, resolution: inputDevice.resolution, captureSession: captureSession)
            self.designatePreviewLayer(for: captureSession)
            return captureSession
        } catch {
            print("Error setting up AVCapture session: \(error.localizedDescription)")
        }
        
        self.teardownAVCapture()
        return nil
    }
    
    fileprivate func configureFrontCamera(for captureSession: AVCaptureSession) throws -> (device: AVCaptureDevice, resolution: CGSize) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw NSError(domain: "ViewController", code: 1, userInfo: [NSLocalizedDescriptionKey: "Front camera not available"])
        }
        
        let input = try AVCaptureDeviceInput(device: device)
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }
        
        if let highestResolution = self.highestResolution420Format(for: device) {
            try device.lockForConfiguration()
            device.activeFormat = highestResolution.format
            device.unlockForConfiguration()
            return (device, highestResolution.resolution)
        } else {
            throw NSError(domain: "ViewController", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to set resolution"])
        }
    }
    
    fileprivate func highestResolution420Format(for device: AVCaptureDevice) -> (format: AVCaptureDevice.Format, resolution: CGSize)? {
        var highestResolutionFormat: AVCaptureDevice.Format?
        var highestResolutionDimensions = CMVideoDimensions(width: 0, height: 0)
        
        for format in device.formats {
            let deviceFormatDescription = format.formatDescription
            if CMFormatDescriptionGetMediaSubType(deviceFormatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
                let candidateDimensions = CMVideoFormatDescriptionGetDimensions(deviceFormatDescription)
                if highestResolutionFormat == nil || candidateDimensions.width > highestResolutionDimensions.width {
                    highestResolutionFormat = format
                    highestResolutionDimensions = candidateDimensions
                }
            }
        }
        
        if let highestFormat = highestResolutionFormat {
            let resolution = CGSize(width: CGFloat(highestResolutionDimensions.width), height: CGFloat(highestResolutionDimensions.height))
            return (highestFormat, resolution)
        }
        
        return nil
    }
    
    fileprivate func configureVideoDataOutput(for inputDevice: AVCaptureDevice, resolution: CGSize, captureSession: AVCaptureSession) {
        let videoDataOutput = AVCaptureVideoDataOutput()
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        let videoDataOutputQueue = DispatchQueue(label: "videoDataOutputQueue")
        videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
        
        if captureSession.canAddOutput(videoDataOutput) {
            captureSession.addOutput(videoDataOutput)
        }
        
        self.videoDataOutput = videoDataOutput
        self.videoDataOutputQueue = videoDataOutputQueue
        self.captureDevice = inputDevice
        self.captureDeviceResolution = resolution
    }
    
    fileprivate func designatePreviewLayer(for captureSession: AVCaptureSession) {
        let videoPreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        videoPreviewLayer.name = "CameraPreview"
        videoPreviewLayer.backgroundColor = UIColor.black.cgColor
        videoPreviewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
        
        DispatchQueue.main.async {
            if let previewRootLayer = self.previewView?.layer {
                self.rootLayer = previewRootLayer
                previewRootLayer.masksToBounds = true
                videoPreviewLayer.frame = previewRootLayer.bounds
                previewRootLayer.addSublayer(videoPreviewLayer)
                self.previewLayer = videoPreviewLayer
            }
        }
    }
    
    fileprivate func teardownAVCapture() {
        self.videoDataOutput = nil
        self.videoDataOutputQueue = nil
        
        DispatchQueue.main.async {
            if let previewLayer = self.previewLayer {
                previewLayer.removeFromSuperlayer()
                self.previewLayer = nil
            }
        }
    }
    
    // MARK: - Vision Setup and Processing
    
    fileprivate func prepareVisionRequest() {
        self.trackingRequests = []
        
        let faceDetectionRequest = VNDetectFaceRectanglesRequest(completionHandler: self.faceDetectionCompletionHandler)
        self.detectionRequests = [faceDetectionRequest]
        
        self.sequenceRequestHandler = VNSequenceRequestHandler()
        
        self.setupVisionDrawingLayers()
    }
    
    func faceDetectionCompletionHandler(request: VNRequest, error: Error?) {
        if error != nil {
            print("FaceDetection error: \(String(describing: error)).")
        }
        
        guard let faceDetectionRequest = request as? VNDetectFaceRectanglesRequest,
              let results = faceDetectionRequest.results else {
            return
        }
        
        DispatchQueue.main.async {
            for observation in results {
                let faceTrackingRequest = VNTrackObjectRequest(detectedObjectObservation: observation)
                self.trackingRequests?.append(faceTrackingRequest)
            }
        }
    }
    
    fileprivate func setupVisionDrawingLayers() {
        guard let rootLayer = self.rootLayer else {
            print("Root layer not initialized")
            return
        }
        
        let overlayLayer = CALayer()
        overlayLayer.name = "DetectionOverlay"
        overlayLayer.masksToBounds = true
        overlayLayer.frame = rootLayer.bounds
        rootLayer.addSublayer(overlayLayer)
        
        let faceRectangleShapeLayer = CAShapeLayer()
        faceRectangleShapeLayer.name = "RectangleOutlineLayer"
        faceRectangleShapeLayer.frame = overlayLayer.bounds
        faceRectangleShapeLayer.fillColor = nil
        faceRectangleShapeLayer.strokeColor = UIColor.green.cgColor
        faceRectangleShapeLayer.lineWidth = 2.0
        overlayLayer.addSublayer(faceRectangleShapeLayer)
        
        let faceLandmarksShapeLayer = CAShapeLayer()
        faceLandmarksShapeLayer.name = "FaceLandmarksLayer"
        faceLandmarksShapeLayer.frame = overlayLayer.bounds
        faceLandmarksShapeLayer.fillColor = nil
        faceLandmarksShapeLayer.strokeColor = UIColor.yellow.cgColor
        faceLandmarksShapeLayer.lineWidth = 1.0
        overlayLayer.addSublayer(faceLandmarksShapeLayer)
        
        self.detectionOverlayLayer = overlayLayer
        self.detectedFaceRectangleShapeLayer = faceRectangleShapeLayer
        self.detectedFaceLandmarksShapeLayer = faceLandmarksShapeLayer
    }
    
    func exifOrientationForCurrentDeviceOrientation() -> CGImagePropertyOrientation {
        let orientation = UIDevice.current.orientation
        switch orientation {
        case .portraitUpsideDown:
            return .left
        case .landscapeLeft:
            return .up
        case .landscapeRight:
            return .down
        default:
            return .right
        }
    }
    
    fileprivate func drawFaceObservations(_ faceObservations: [VNFaceObservation]) {
        guard let faceRectangleShapeLayer = self.detectedFaceRectangleShapeLayer,
              let faceLandmarksShapeLayer = self.detectedFaceLandmarksShapeLayer else {
            return
        }
        
        CATransaction.begin()
        CATransaction.setValue(true, forKey: kCATransactionDisableActions)
        
        let faceRectanglePath = CGMutablePath()
        let faceLandmarksPath = CGMutablePath()
        
        for faceObservation in faceObservations {
            let boundingBox = faceObservation.boundingBox
            
            let convertedBoundingBox = VNImageRectForNormalizedRect(boundingBox,
                                                                    Int(self.captureDeviceResolution.width),
                                                                    Int(self.captureDeviceResolution.height))
            faceRectanglePath.addRect(convertedBoundingBox)
            
            if let landmarks = faceObservation.landmarks {
                let affineTransform = CGAffineTransform(translationX: convertedBoundingBox.origin.x, y: convertedBoundingBox.origin.y)
                    .scaledBy(x: convertedBoundingBox.size.width, y: convertedBoundingBox.size.height)
                
                if let leftEye = landmarks.leftEye {
                    self.addPoints(in: leftEye, to: faceLandmarksPath, applying: affineTransform, closePath: true)
                }
            }
        }
        
        faceRectangleShapeLayer.path = faceRectanglePath
        faceLandmarksShapeLayer.path = faceLandmarksPath
        
        CATransaction.commit()
    }
    
    fileprivate func addPoints(in landmarkRegion: VNFaceLandmarkRegion2D, to path: CGMutablePath, applying affineTransform: CGAffineTransform, closePath: Bool) {
        let points = landmarkRegion.normalizedPoints
        if points.count > 1 {
            path.move(to: points[0], transform: affineTransform)
            path.addLines(between: points, transform: affineTransform)
            if closePath {
                path.closeSubpath()
            }
        }
    }
    
    fileprivate func performInitialDetection(pixelBuffer: CVPixelBuffer, exifOrientation: CGImagePropertyOrientation, requestHandlerOptions: [VNImageOption: AnyObject]) {
        let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: exifOrientation, options: requestHandlerOptions)
        
        do {
            if let detectRequests = self.detectionRequests {
                try imageRequestHandler.perform(detectRequests)
            }
        } catch {
            print("Failed to perform initial face detection.")
        }
    }
    
    fileprivate func performTracking(requests: [VNTrackObjectRequest], pixelBuffer: CVPixelBuffer, exifOrientation: CGImagePropertyOrientation) {
        do {
            try self.sequenceRequestHandler.perform(requests, on: pixelBuffer, orientation: exifOrientation)
        } catch {
            print("Failed to perform tracking.")
        }
        
        var newTrackingRequests = [VNTrackObjectRequest]()
        for trackingRequest in requests {
            if let results = trackingRequest.results,
               let observation = results.first as? VNDetectedObjectObservation, observation.confidence > 0.3 {
                trackingRequest.inputObservation = observation
                newTrackingRequests.append(trackingRequest)
            }
        }
        self.trackingRequests = newTrackingRequests
    }
}

extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        var requestHandlerOptions: [VNImageOption: AnyObject] = [:]
        
        let cameraIntrinsicData = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil)
        if cameraIntrinsicData != nil {
            requestHandlerOptions[VNImageOption.cameraIntrinsics] = cameraIntrinsicData
        }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("Failed to obtain a CVPixelBuffer for the current output frame.")
            return
        }
        
        let exifOrientation = self.exifOrientationForCurrentDeviceOrientation()
        
        guard let requests = self.trackingRequests else {
            print("Tracking request array not setup, aborting.")
            return
        }
        
        if requests.isEmpty {
            self.performInitialDetection(pixelBuffer: pixelBuffer,
                                         exifOrientation: exifOrientation,
                                         requestHandlerOptions: requestHandlerOptions)
            return
        }
        
        self.performTracking(requests: requests,
                             pixelBuffer: pixelBuffer,
                             exifOrientation: exifOrientation)
    }
}
