//
//  CameraContextPanelManager.swift
//  leanring-buddy
//
//  Camera as context. "Read this page" / "what am I holding?" opens a small
//  live preview of the webcam in a glass card, grabs a frame, runs the same
//  on-device OCR as the screen path, draws the recognized lines over the live
//  preview, and hands the frame plus its text to the model. Physical pages,
//  whiteboards and labels come into the same conversation as the screen.
//

import AppKit
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class CameraContextModel: ObservableObject {
    @Published var recognizedLines: [RecognizedTextLine] = []
    @Published var frameSize: CGSize = .zero
    @Published var status: String = "warming up…"
}

private final class CameraPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Keeps the newest frame from the capture session.
private final class LatestFrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latestPixelBuffer = pixelBuffer
        lock.unlock()
    }

    nonisolated func latestImage() -> CGImage? {
        lock.lock()
        let pixelBuffer = latestPixelBuffer
        lock.unlock()
        guard let pixelBuffer else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return CIContext().createCGImage(ciImage, from: ciImage.extent)
    }
}

@MainActor
final class CameraContextPanelManager {
    private let model = CameraContextModel()
    private var panel: CameraPanel?
    private let session = AVCaptureSession()
    private let frameSink = LatestFrameSink()
    private var isConfigured = false
    private var hideTask: Task<Void, Never>?
    private static let panelSize = CGSize(width: 480, height: 372)

    var isShowing: Bool { panel?.isVisible ?? false }

    /// Shows the live preview (asking for camera access the first time). Returns
    /// false when there is no camera or access was refused.
    func show() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { return false }
        } else if status != .authorized {
            return false
        }
        if !isConfigured { guard configureSession() else { return false } }
        if panel == nil { createPanel() }
        guard let panel, let screen = NSScreen.main else { return false }
        hideTask?.cancel()
        model.recognizedLines = []
        model.status = "warming up…"
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.maxX - Self.panelSize.width - 24, y: visible.minY + 24, width: Self.panelSize.width, height: Self.panelSize.height), display: true)
        if !session.isRunning {
            let session = self.session
            await Task.detached { session.startRunning() }.value
        }
        fadeIn(panel)
        return true
    }

    /// Kept synchronous: an animation group closure inside an async method trips the isolation checker.
    private func fadeIn(_ panel: NSPanel) {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        hideTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.panel?.orderOut(nil)
                let session = self.session
                Task.detached { session.stopRunning() }
            }
        })
    }

    func scheduleHide(afterSeconds seconds: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// The newest frame, waiting briefly for exposure to settle after start.
    func captureFrame() async -> CGImage? {
        for _ in 0..<12 {
            if let image = frameSink.latestImage() { return image }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return nil
    }

    func showRecognizedLines(_ lines: [RecognizedTextLine], frameSize: CGSize, status: String) {
        model.frameSize = frameSize
        model.status = status
        withAnimation(.easeOut(duration: 0.35)) {
            model.recognizedLines = Array(lines.prefix(40))
        }
    }

    func setStatus(_ status: String) {
        model.status = status
    }

    // MARK: - Setup

    private func configureSession() -> Bool {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(frameSink, queue: DispatchQueue(label: "octo.camera.frames"))
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        isConfigured = true
        return true
    }

    private func createPanel() {
        let hosting = NSHostingView(rootView: CameraContextView(model: model, session: session, onClose: { [weak self] in self?.hide() }))
        let cameraPanel = CameraPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        cameraPanel.level = .statusBar
        cameraPanel.isOpaque = false
        cameraPanel.backgroundColor = .clear
        cameraPanel.hasShadow = true
        cameraPanel.hidesOnDeactivate = false
        cameraPanel.isExcludedFromWindowsMenu = true
        cameraPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        cameraPanel.contentView = hosting
        panel = cameraPanel
    }
}

// MARK: - Views

/// Live preview, not mirrored, so text held up to the camera reads the right way round.
private struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        if let connection = previewLayer.connection {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        previewLayer.frame = view.bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(previewLayer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct CameraContextView: View {
    @ObservedObject var model: CameraContextModel
    let session: AVCaptureSession
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DS.Colors.overlayCursorBlue)
                Text("CAMERA")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(DS.Colors.overlayCursorBlue)
                    .tracking(0.8)
                Text(model.status)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    CameraPreviewView(session: session)
                    // OCR boxes mapped from frame pixels to the aspect-fit preview.
                    if model.frameSize.width > 0 {
                        let scale = min(proxy.size.width / model.frameSize.width, proxy.size.height / model.frameSize.height)
                        let offsetX = (proxy.size.width - model.frameSize.width * scale) / 2
                        let offsetY = (proxy.size.height - model.frameSize.height * scale) / 2
                        ForEach(Array(model.recognizedLines.enumerated()), id: \.offset) { _, line in
                            let box = line.boundingBoxInCapturePixels
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(DS.Colors.overlayCursorBlue.opacity(0.16))
                                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(DS.Colors.overlayCursorBlue.opacity(0.85), lineWidth: 1.5))
                                .frame(width: box.width * scale + 4, height: box.height * scale + 4)
                                .offset(x: offsetX + box.minX * scale - 2, y: offsetY + box.minY * scale - 2)
                                .transition(.opacity)
                        }
                    }
                }
            }
            .frame(width: 452, height: 306)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .padding(14)
        .frame(width: 480, alignment: .leading)
        .background(GlassCardBackground(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
    }
}
