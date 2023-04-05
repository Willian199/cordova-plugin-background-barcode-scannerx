import Foundation
import AVFoundation
import AudioToolbox
import ZXingObjC

@objc(BBScanner)
class BBScanner : CDVPlugin, ZXCaptureDelegate {

    class CameraView: UIView {
        var _capture:ZXCapture?

        func addPreviewLayer(_ capture:ZXCapture){

            capture.layer.frame = self.bounds
            self.layer.addSublayer(capture.layer)

            let orientation:UIInterfaceOrientation = UIApplication.shared.statusBarOrientation

            var scanRectRotation:CGFloat;
            var captureRotation:Double;

            switch (orientation) {
                case UIInterfaceOrientation.portrait:
                    captureRotation = 0;
                    scanRectRotation = 90;
                    break;
                case UIInterfaceOrientation.landscapeLeft:
                    captureRotation = 90;
                    scanRectRotation = 180;
                    break;
                case UIInterfaceOrientation.landscapeRight:
                    captureRotation = 270;
                    scanRectRotation = 0;
                    break;
                case UIInterfaceOrientation.portraitUpsideDown:
                    captureRotation = 180;
                    scanRectRotation = 270;
                    break;
                default:
                    captureRotation = 0;
                    scanRectRotation = 90;
                    break;
            }

            capture.transform = CGAffineTransform( rotationAngle: CGFloat((captureRotation / 180 * .pi)) )
            capture.rotation  = scanRectRotation

            self._capture = capture

        }

        func removePreviewLayer() {
            self._capture?.layer.removeFromSuperlayer()
            self._capture = nil
        }
    }

    var cameraView: CameraView!
    var capture: ZXCapture!

    var currentCamera: Int = 0;
    var frontCamera: Int32 = -1;
    var backCamera: Int32 = -1;

    var scanning: Bool = false
    var paused: Bool = false
    var multipleScan: Bool = false
    var nextScanningCommand: CDVInvokedUrlCommand?

    enum ScannerError: Int32 {
        case unexpected_error = 0,
        camera_access_denied = 1,       
        back_camera_unavailable = 3,
        front_camera_unavailable = 4,
        camera_unavailable = 5,
        scan_canceled = 6,
        light_unavailable = 7,
        open_settings_unavailable = 8,
        camera_access_restricted = 9,
    }

    enum CaptureError: Error {
        case backCameraUnavailable
        case frontCameraUnavailable
        case couldNotCaptureInput(error: NSError)
    }

    enum LightError: Error {
        case torchUnavailable
    }


    /// Function that sets up the `pageDidLoad` observer.
    ///
    /// This function sets up an observer for the `CDVPageDidLoad` notification, and when the page loads, it calls the `initSubView` function.
    override func pluginInitialize() {
        super.pluginInitialize()
        NotificationCenter.default.addObserver(self, selector: #selector(pageDidLoad), name: NSNotification.Name.CDVPageDidLoad, object: nil)
        self.initSubView()
    }

    /// Function to initialize the `CameraView` object.
    ///
    /// This function will initialize the `CameraView` object with a given frame and add the appropriate resizing masks. 
    /// It is called in the `pageDidLoad` method and ensures that the `CameraView` object is only initialized once.
    func initSubView() {
        if self.cameraView == nil {
            self.cameraView = CameraView(frame: CGRect(x: self.webView.frame.origin.x, y: self.webView.frame.origin.y, width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height))
            self.cameraView.autoresizingMask = [.flexibleWidth, .flexibleHeight];
        }
    }

    // Send error to console javascript
    func sendErrorCode(command: CDVInvokedUrlCommand, error: ScannerError){
        let pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: error.rawValue)
        commandDelegate!.send(pluginResult, callbackId:command.callbackId)
    }

    /// Prepares the scanner by checking the authorization status for the camera and setting up the camera view.
    ///
    /// - Parameter command: The command received from the JavaScript code.
    /// - Returns: A boolean value indicating whether the preparation was successful or not.
    func prepScanner(command: CDVInvokedUrlCommand) -> Bool{
        if checkCameraPermission(command: command, requestAccess: true) {
            do {

                if let capture = self.capture {
                    return true
                }

                self.initSubView()

                capture = ZXCapture()
                capture.delegate = self
                capture.camera = capture.back()
                backCamera = capture.back()
                frontCamera = capture.front()
                capture.focusMode = .continuousAutoFocus

                cameraView.backgroundColor = .clear
                webView!.superview!.insertSubview(cameraView, belowSubview: webView!)
                cameraView.addPreviewLayer(capture)

                return true
            } catch {
                self.sendErrorCode(command: command, error: ScannerError.unexpected_error)
            }
        }
        return false
    }

    /**
        Function that verifies if the application has permission to access the camera. If the permission was not granted yet, it will request it.

        - Parameter command: the command object used to send result back to the caller.
        - Parameter requestAccess: a flag indicating if the function should request access to the camera if it was not granted yet.

        - Returns: a boolean indicating if the application has permission to access the camera.
    */
    func checkCameraPermission(command: CDVInvokedUrlCommand, requestAccess: Bool) -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: AVMediaType.video)
        switch status {
            case .restricted:
                self.sendErrorCode(command: command, error: ScannerError.camera_access_restricted)
                return false
            case .denied:
                self.sendErrorCode(command: command, error: ScannerError.camera_access_denied)
                return false
            case .authorized:
                return true
            case .notDetermined:
                if requestAccess {
                    AVCaptureDevice.requestAccess(for: AVMediaType.video) { granted in
                        if granted {
                            return true
                        } else {
                            self.sendErrorCode(command: command, error: ScannerError.camera_access_denied)
                            return false
                        }
                    }
                } else {
                    return false
                }
            @unknown default:
                return false
        }
    }

    func boolToNumberString(bool: Bool) -> String{
        return  bool ? "1" : "0"       
    }

    /**
        Function that enables the light of the camera.

        - Parameter command: the command object used to send result back to the caller.
    */
    @objc
    func enableLight(_ command: CDVInvokedUrlCommand) {
        if checkCameraPermission(command: command, requestAccess: false) {
            self.configureLight(command: command, state: true)
        }
    }

    /**
        Function that disables the light of the camera.

        - Parameter command: the command object used to send result back to the caller.
    */
    @objc
    func disableLight(_ command: CDVInvokedUrlCommand) {
        if checkCameraPermission(command: command, requestAccess: false) {
            self.configureLight(command: command, state: false)
        }
    }

    /**
    Configures the camera light.

    - Parameter command: The CDVInvokedUrlCommand object that contains information about the command.
    - Parameter state: A boolean indicating whether to turn on (true) or turn off (false) the light.

    - Note: If the torch is unavailable, a "light_unavailable" error is sent to the JavaScript callback.
    - Note: If there is an unexpected error, an error with the code "unexpected_error" is sent to the JavaScript callback.
    */
    func configureLight(command: CDVInvokedUrlCommand, state: Bool){

        do {
            // Check if the torch is available for use
            guard let captureDevice = self.capture.captureDevice, captureDevice.hasTorch else {
                throw LightError.torchUnavailable
            }
            
            try captureDevice.lockForConfiguration()
            // Turn on the torch
            if (state) {
                try captureDevice.setTorchModeOn(level: 1)
            } else {
                // Turn off the torch if it's on
                if (captureDevice.torchMode == .on) {
                    captureDevice.torchMode = .off
                }
            }
            captureDevice.unlockForConfiguration()

            self.getStatus(command)
        } catch LightError.torchUnavailable {
            // Return torch unavailable error
            self.sendErrorCode(command: command, error: ScannerError.light_unavailable)
        } catch let error as NSError {
            print(error.localizedDescription)
            self.sendErrorCode(command: command, error: ScannerError.unexpected_error)
        }
    }

    /// Handles the result of a barcode scan
    /// - Parameter capture: The `ZXCapture` instance that performed the scan
    /// - Parameter result: The `ZXResult` instance that holds the result of the scan
    func captureResult(_ capture: ZXCapture, result: ZXResult) {
        // Exit early if scanning is not currently in progress or if the result is nil
        guard scanning, let resultText = result.text else { return }

        // Check if there are options for the format of the barcode to be scanned
        if let options = nextScanningCommand?.arguments[0] as? [String: Any], let format = options["format"] as? String {
            let barcodeFormat = stringToBarcodeFormat(format: format)
            // Exit early if the format of the result doesn't match the desired format
            guard barcodeFormat == result.barcodeFormat else { return }
        }

        // Create a `CDVPluginResult` instance with the scan result and set its keep callback flag
        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: resultText)
        pluginResult.setKeepCallbackAs(multipleScan)
        // Send the result back to the caller
        commandDelegate?.send(pluginResult, callbackId: nextScanningCommand?.callbackId)

        // If multiple scans are not enabled, clean up the scanning resources
        if !multipleScan {
            nextScanningCommand = nil
            scanning = false
            capture.destroy()
        }
    }

    // Return an ZXBarcodeFormat from a string
    func stringToBarcodeFormat(format: String)->ZXBarcodeFormat{
        switch format {
            case "AZTEC": return kBarcodeFormatAztec
            case "CODABAR": return kBarcodeFormatCodabar
            case "CODE_39": return kBarcodeFormatCode39
            case "CODE_93": return kBarcodeFormatCode93
            case "CODE_128": return kBarcodeFormatCode128
            case "DATA_MATRIX": return kBarcodeFormatDataMatrix
            case "EAN_8": return kBarcodeFormatEan8
            case "EAN_13": return kBarcodeFormatEan13
            case "ITF": return kBarcodeFormatITF
            case "PDF417": return kBarcodeFormatPDF417
            case "QR_CODE": return kBarcodeFormatQRCode
            case "RSS_14": return kBarcodeFormatRSS14
            case "RSS_EXPANDED": return kBarcodeFormatRSSExpanded
            case "UPC_A": return kBarcodeFormatUPCA
            case "UPC_E": return kBarcodeFormatUPCE
            case "UPC_EAN_EXTENSION": return kBarcodeFormatUPCEANExtension
            default: return kBarcodeFormatEan13
        }
    }

    // Return an String from ZXBarcodeFormat
    func barcodeFormatToString(format:ZXBarcodeFormat)->String {
        switch (format) {
            case kBarcodeFormatAztec: return "AZTEC";
            case kBarcodeFormatCodabar: return "CODABAR";
            case kBarcodeFormatCode39: return "CODE_39";
            case kBarcodeFormatCode93: return "CODE_93";
            case kBarcodeFormatCode128: return "CODE_128";
            case kBarcodeFormatDataMatrix: return "DATA_MATRIX";
            case kBarcodeFormatEan8: return "EAN_8";
            case kBarcodeFormatEan13: return "EAN_13";
            case kBarcodeFormatITF: return "ITF";
            case kBarcodeFormatPDF417: return "PDF417";
            case kBarcodeFormatQRCode: return "QR_CODE";
            case kBarcodeFormatRSS14: return "RSS_14";
            case kBarcodeFormatRSSExpanded: return "RSS_EXPANDED";
            case kBarcodeFormatUPCA: return "UPCA";
            case kBarcodeFormatUPCE: return "UPC_E";
            case kBarcodeFormatUPCEANExtension: return "UPC_EAN_EXTENSION";
            default: return "UNKNOWN";
        }
    }

    @objc func pageDidLoad() {
        self.webView?.isOpaque = false
        self.webView?.backgroundColor = UIColor.clear
        self.clearBackgrounds(subviews: self.webView.subviews)
    }

    /// Runs a background task with an optional delay and completion block
    /// - Parameter delay: The delay in seconds before the completion block is executed (default is 0.0)
    /// - Parameter background: The block of code to be executed in the background
    /// - Parameter completion: The block of code to be executed on the main queue after the delay
    func backgroundThread(delay: Double = 0.0, background: (() -> Void)? = nil, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            background?()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                completion?()
            }
        }
    }
    
    /// Prepares the scanner and handles the camera authorization status.
    /// - Parameter command: The command to be passed to other functions.
    @objc
    func prepare(_ command: CDVInvokedUrlCommand){

        guard self.prepScanner(command: command) else { return }

        self.cameraView?.isHidden = true
        self.capture?.stop()
        self.getStatus(command)
    }

    /// Helper method to clear background of subviews
    private func clearBackgrounds(subviews: [UIView]?) {
        subviews?.forEach { subview in
            subview.isOpaque = false
            subview.backgroundColor = .clear
            subview.scrollView.backgroundColor = .clear
            clearBackgrounds(subviews: subview.subviews)
        }
    }

    /// Starts a scan operation
    /// - Parameter command: The `CDVInvokedUrlCommand` object passed from JavaScript
    @objc
    func scan(_ command: CDVInvokedUrlCommand) {
        guard self.prepScanner(command: command) else { return }
        
        nextScanningCommand = command
        scanning = true

        if let jsonString = command.argument(at: 0) as? String,
            let jsonData = jsonString.data(using: .utf8) {
                do {
                    let options = try JSONDecoder().decode([String: Any].self, from: jsonData)
                    self.multipleScan = options["multipleScan"] as? Bool ?? false
                } catch {
                    self.sendErrorCode(command: command, error: ScannerError.unexpected_error)
                }
        }
        
        webView?.isOpaque = false
        webView?.backgroundColor = .clear
        clearBackgrounds(subviews: webView?.subviews)
        cameraView.isHidden = false
        
        if !capture.isRunning {
            capture.start()
        }
    }

    /// Pauses the scanning process.
    ///
    /// - Parameter command: The command received from the JavaScript code.
    @objc
    func pause(_ command: CDVInvokedUrlCommand) {
        scanning = false
        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK)
        commandDelegate!.send(pluginResult, callbackId: command.callbackId)
    }

    /// Resumes the scanning process.
    ///
    /// - Parameter command: The command received from the JavaScript code.
    @objc
    func resume(_ command: CDVInvokedUrlCommand) {
        scanning = true
        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK)
        commandDelegate!.send(pluginResult, callbackId:command.callbackId)
    }

    @objc
    func stop(_ command: CDVInvokedUrlCommand){
        if self.prepScanner(command: command) {
            scanning = false
            self.cameraView.isHidden = true
            self.capture.stop()

            if(nextScanningCommand != nil){
                self.sendErrorCode(command: nextScanningCommand!, error: ScannerError.scan_canceled)
            }
            self.getStatus(command)
        }
    }

    @objc
    func snap(_ command: CDVInvokedUrlCommand) {
        if self.prepScanner(command: command) {
            let image = UIImage(cgImage: self.capture.lastScannedImage)
            let resizedImage = image.resizeImage(640, opaque: true)
            let data = resizedImage.pngData()
            let base64 = data?.base64EncodedString()
            let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: base64)
            commandDelegate!.send(pluginResult, callbackId:command.callbackId)
        }
    }


    // backCamera is 0, frontCamera is 1

    @objc
    func switchCamera(_ command: CDVInvokedUrlCommand){
        let index = command.arguments[0] as! Int
        if(currentCamera != index){
           // camera change only available if both backCamera and frontCamera exist
           if(backCamera != -1 && frontCamera != -1){
               // switch camera
               currentCamera = index
               if(self.prepScanner(command: command)){
                    if (currentCamera == 0) {
                    self.capture.camera = backCamera
                   } else {
                    self.capture.camera = frontCamera
                   }
                }
           } else {
               if(backCamera == -1){
                   self.sendErrorCode(command: command, error: ScannerError.back_camera_unavailable)
               } else {
                   self.sendErrorCode(command: command, error: ScannerError.front_camera_unavailable)
               }
           }
       } else {
           // immediately return status if camera is unchanged
           self.getStatus(command)
       }
    }

    /**
        Destroys the camera capture object and removes its associated view.

        - Parameter command: The CDVInvokedUrlCommand object that contains information about the command.
    */
    @objc func destroy(_ command: CDVInvokedUrlCommand) {
        if let cameraView = self.cameraView {
            cameraView.isHidden = true
            cameraView.removePreviewLayer()
            cameraView.removeFromSuperview()
        }
        self.cameraView = nil

        if let capture = self.capture {
            capture.stop()
        }
        self.capture = nil
        
        self.currentCamera = 0

        self.getStatus(command)
    }

    // Return the plugin's status to javscript console
    @objc
    func getStatus(_ command: CDVInvokedUrlCommand){

        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: AVMediaType.video);

        let authorized = (authorizationStatus == AVAuthorizationStatus.authorized)

        let denied = (authorizationStatus == AVAuthorizationStatus.denied)

        let restricted = (authorizationStatus == AVAuthorizationStatus.restricted)

        let prepared = (self.capture != nil && self.capture.running == true)

        let showing = (self.webView!.backgroundColor == UIColor.clear)

        var lightEnabled = false
        var canEnableLight = false
        
        if (self.capture != nil && self.capture.captureDevice != nil) {
            if(self.capture.captureDevice.hasTorch){
                canEnableLight = true
            }
            if(self.capture.captureDevice.isTorchActive){
                lightEnabled = true
            }
        }

        let canOpenSettings = "1"
        let previewing = "0"

        let canChangeCamera =  (backCamera != -1 && frontCamera != -1)

        let status = [
            "authorized": boolToNumberString(bool: authorized),
            "denied": boolToNumberString(bool: denied),
            "restricted": boolToNumberString(bool: restricted),
            "prepared": boolToNumberString(bool: prepared),
            "scanning": boolToNumberString(bool: self.scanning),
            "previewing": previewing,
            "showing": boolToNumberString(bool: showing),
            "lightEnabled": boolToNumberString(bool: lightEnabled),
            "canOpenSettings": canOpenSettings,
            "canEnableLight": boolToNumberString(bool: canEnableLight),
            "canChangeCamera": boolToNumberString(bool: canChangeCamera),
            "currentCamera": String(currentCamera)
        ]

        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: status)
        commandDelegate!.send(pluginResult, callbackId:command.callbackId)
    }


    // Open native settings
    @objc
    func openSettings(_ command: CDVInvokedUrlCommand) {
        guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
                return
            }
            if UIApplication.shared.canOpenURL(settingsUrl) {
                UIApplication.shared.open(settingsUrl, completionHandler: { (success) in
                    self.getStatus(command)
                })
            } else {
                self.sendErrorCode(command: command, error: ScannerError.open_settings_unavailable)
            }
        
    }
}

extension UIImage {
    func resizeImage(_ dimension: CGFloat, opaque: Bool, contentMode: UIView.ContentMode = .scaleAspectFit) -> UIImage {
        var width: CGFloat
        var height: CGFloat
        var newImage: UIImage

        let size = self.size
        let aspectRatio =  size.width/size.height

        switch contentMode {
            case .scaleAspectFit:
                if aspectRatio > 1 {                            // Landscape image
                    width = dimension
                    height = dimension / aspectRatio
                } else {                                        // Portrait image
                    height = dimension
                    width = dimension * aspectRatio
                }

        default:
            fatalError("UIIMage.resizeToFit(): FATAL: Unimplemented ContentMode")
        }

        let renderFormat = UIGraphicsImageRendererFormat.default()
        renderFormat.opaque = opaque
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: renderFormat)
        newImage = renderer.image {
            (context) in
            self.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        return newImage
    }
}
