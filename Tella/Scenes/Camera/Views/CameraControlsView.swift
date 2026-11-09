//
//  Copyright © 2022 HORIZONTAL.
//  Licensed under MIT (https://github.com/Horizontal-org/Tella-iOS/blob/develop/LICENSE)
//



import SwiftUI

struct CameraControlsView: View {
    // MARK: - Public properties
    @ObservedObject var cameraViewModel: CameraViewModel
    @Binding var showingCameraView : Bool
    var sourceView : SourceView
    @Binding var gridIsOn: Bool
    
    var captureButtonAction: (() -> Void)
    var recordVideoAction: (() -> Void)
    var toggleCamera: (() -> Void)
    var updateCameraTypeAction: ((CameraType) -> Void)
    var updateFlashMode: ((CameraFlashMode) -> Void)
    var close: (() -> Void)
    var zoomFactor: CGFloat = 1.0
    var flashMode: CameraFlashMode = .off
    var isFlashAvailable: Bool = true
    
    // MARK: - Private properties
    
    @State private var selectedOption: CameraType = .video   // SPECTRE: opens in video mode
    @State private var state : CameraState = .readyRecordingVideo
    @State private var shouldHideCloseButton: Bool = false
    
    
    @State private var  deviceOrientation : UIDeviceOrientation = UIDevice.current.orientation
    @State private var shouldAnimate: Bool = false
    
    var body: some View {
        
        VStack {
            
            cameraHeaderView()
            
            Spacer()
            
            zoomFactorLabel
            
            switch state {
                
            case .readyTakingImage:
                capturePhotoControllers
                
            case .readyRecordingVideo:
                recordVideoControllers
                
            case .recordingVideo:
                recordingVideoControllers
            }
        }
        .onReceive(cameraViewModel.mainAppModel.$shouldSaveCurrentData) { value in
            if(value && state == .recordingVideo) {
                stopRecordingVideo()
            }
        }
    }
    
    var zoomFactorLabel: some View {
        
        CustomText(formattedZoomFactor, style: .subheading1Style)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.5))
            .clipShape(Capsule())
            .padding(.bottom, 20)
            .rotate(deviceOrientation: deviceOrientation,
                    shouldAnimate: shouldAnimate)
        
    }
    
    private var formattedZoomFactor: String {
        let roundedValue = (zoomFactor * 10).rounded() / 10
        let isWholeNumber = roundedValue.truncatingRemainder(dividingBy: 1) == 0
        let text = isWholeNumber ? String(Int(roundedValue)) : String(format: "%.1f", roundedValue)
        return "\(text)x"
    }
    
    private func cameraHeaderView() -> some View {
        HStack() {
            closeButton
            Spacer()
            gridButton
            flashButton
        }
        .padding(.top, .smallMedium)
        .frame(height: 90)
        .background(Color.black.opacity(0.8))
        .edgesIgnoringSafeArea(.all)
    }
    
    @ViewBuilder
    var closeButton: some View {
        if !shouldHideCloseButton {
            Button {
                
                if sourceView == .tab {
                    cameraViewModel.mainAppModel.selectedTab = .home
                } else {
                    showingCameraView = false
                }
                
                close()
                
            } label: {
                Image(.close)
                    .padding(.normal)
            }
            .rotate(deviceOrientation: self.deviceOrientation,
                    shouldAnimate: self.shouldAnimate)
        }
    }
    
    var flashButton: some View {
        Button {
            updateFlashMode(flashMode.next)
        } label: {
            flashIcon
                .padding(.normal)
        }
        .disabled(!isFlashAvailable)
        .opacity(isFlashAvailable ? 1 : 0.4)
        .rotate(deviceOrientation: self.deviceOrientation,
                shouldAnimate: self.shouldAnimate)
    }
    
    @ViewBuilder
    private var flashIcon: some View {
        switch flashMode {
        case .auto:
            Image(.cameraFlashAuto)
        case .on:
            Image(.cameraFlashOn)
        case .off:
            Image(.cameraFlashOff)
        }
    }
    
    var gridButton: some View {
        Button {
            gridIsOn.toggle()
        } label: {
            Image(gridIsOn ? .cameraGridOn : .cameraGridOff)
                .padding(.normal)
        }
        
        .rotate(deviceOrientation: self.deviceOrientation,
                shouldAnimate: self.shouldAnimate)
        .accessibilityLabel(gridIsOn
                            ? LocalizableCamera.hideGrid.localized
                            : LocalizableCamera.showGrid.localized)
    }
    
    // MARK: - SPECTRE: native-style controls (thumbnail · shutter · flip, mode labels below)

    var capturePhotoControllers : some View {
        nativeControls
            .onAppear(perform: {
                DeviceOrientationHelper().startDeviceOrientationNotifier { deviceOrientation in
                    self.deviceOrientation = deviceOrientation
                    shouldAnimate = true
                }
            })
    }

    var recordVideoControllers : some View {
        capturePhotoControllers
    }

    var recordingVideoControllers : some View {
        nativeControls
    }

    private var isRecording: Bool { state == .recordingVideo }

    private var nativeControls: some View {
        VStack(spacing: 0) {
            if isRecording {
                Text(cameraViewModel.formattedCurrentTime)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.red)
                    .cornerRadius(4)
                    .padding(.bottom, 12)
            }
            HStack {
                Group {
                    if isRecording { Color.clear } else { previewImageAndVideodFile }
                }
                .frame(width: 52, height: 52)
                Spacer()
                shutterButton
                Spacer()
                Group {
                    if isRecording { Color.clear } else { flipCamera }
                }
                .frame(width: 52, height: 52)
            }
            .padding(.horizontal, 32)
            .padding(.top, 14)
            if !isRecording {
                bottomMenu
                    .padding(.top, 14)
            } else {
                Spacer().frame(height: 44)
            }
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            guard !isRecording, abs(value.translation.width) > abs(value.translation.height) else { return }
            // Like the iPhone camera: swipe left/right to change mode.
            select(value.translation.width < 0 ? .image : .video)
        })
    }

    private var shutterButton: some View {
        Button {
            switch state {
            case .readyTakingImage:
                captureButtonAction()
            case .readyRecordingVideo:
                shouldHideCloseButton = true
                state = .recordingVideo
                recordVideoAction()
                cameraViewModel.initialiseTimerRunning()
            case .recordingVideo:
                stopRecordingVideo()
            }
        } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 74, height: 74)
                if isRecording {
                    RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 30, height: 30)
                } else {
                    Circle().fill(state == .readyRecordingVideo ? Color.red : Color.white).frame(width: 62, height: 62)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: state)
        }
        .frame(width: 80, height: 80)
        .accessibilityLabel(isRecording ? "Arrêter" : (state == .readyRecordingVideo ? "Filmer" : "Prendre une photo"))
    }

    private func select(_ type: CameraType) {
        guard selectedOption != type, !isRecording else { return }
        withAnimation(.interactiveSpring()) { selectedOption = type }
        updateCameraTypeAction(type)
        state = type == .video ? .readyRecordingVideo : .readyTakingImage
    }

    @ViewBuilder
    var previewImageAndVideodFile : some View {
        VStack {
            if let file = $cameraViewModel.lastImageOrVideoVaultFile.wrappedValue,
               let data = file.thumbnail {
                
                Button {
                    navigateTo(destination: getFileListView())
                } label: {
                    UIImage.image(fromData:data)
                        .rounded()
                }
            } else {
                Spacer()
                    .frame(width: 40, height: 40)
            }
        }.rotate(deviceOrientation: self.deviceOrientation,
                 shouldAnimate: self.shouldAnimate)
    }
    
    var flipCamera: some View {
        Button {
            toggleCamera()
        } label: {
            Image(.cameraFlipCamera)
        }.frame(width: 40, height: 40)
            .rotate(deviceOrientation: self.deviceOrientation,
                    shouldAnimate: self.shouldAnimate)
    }
    
    func getFileListView() -> FileListView {
        FileListView(mainAppModel: cameraViewModel.mainAppModel,
                     filterType: .photoVideo,
                     title: LocalizableCamera.appBar.localized,
                     fileListType: .cameraGallery)
    }
    
    var bottomMenu : some View {
        HStack(spacing: 28) {
            modeLabel(LocalizableCamera.tabTitleVideo.localized.uppercased(), .video)
            modeLabel(LocalizableCamera.tabTitlePhoto.localized.uppercased(), .image)
        }
    }

    private func modeLabel(_ title: String, _ type: CameraType) -> some View {
        Button { select(type) } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .kerning(1)
                .foregroundColor(selectedOption == type ? .white : .white.opacity(0.45))
        }
    }

    private func stopRecordingVideo() {
        shouldHideCloseButton = false
        state = .readyRecordingVideo
        recordVideoAction()
        cameraViewModel.invalidateTimerRunning()
    }
}

struct CameraControlsView_Previews: PreviewProvider {
    static var previews: some View {
        CameraControlsView(cameraViewModel: CameraViewModel.stub(),
                           showingCameraView:.constant(false),
                           sourceView: .tab,
                           gridIsOn: .constant(false)) {
            
        } recordVideoAction: {
            
        } toggleCamera: {
            
        } updateCameraTypeAction: { value in
            
        } updateFlashMode: { _ in
        } close: {}
    }
}

private extension CameraFlashMode {
    var next: CameraFlashMode {
        switch self {
        case .auto:
            return .on
        case .on:
            return .off
        case .off:
            return .auto
        }
    }
}

private extension LocalizableCamera {
    func localized(or fallback: String) -> String {
        Bundle.main.localizedString(forKey: rawValue, value: fallback, table: table)
    }
}
