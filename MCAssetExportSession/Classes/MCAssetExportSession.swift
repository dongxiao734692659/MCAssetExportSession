//
//  MCAssetExportSession.swift
//  export_video
//
//  Created by 董潇 on 2021/6/21.
//

import UIKit
import Foundation
import AVFoundation

@available(iOS 10.0, *)
public protocol MCAssetExportSessionDelegate {
    func assetExportSessionDidProgress(assetExportSession: MCAssetExportSession)
    
    func assetExportSession(_ assetExportSession: MCAssetExportSession , _ renderFrame: CVPixelBuffer, _ withPresentationTime: CMTime, _ toBuffer: CVPixelBuffer)
}

public enum MCAssetExportSessionPreset {
    
    case MCAssetExportSessionPreset240P
    case MCAssetExportSessionPreset360P
    case MCAssetExportSessionPreset480P
    case MCAssetExportSessionPreset540P
    case MCAssetExportSessionPreset720P
    case MCAssetExportSessionPreset1080P
    case MCAssetExportSessionPreset2K // 1440P
    case MCAssetExportSessionPreset4K // 2160P
}

@available(iOS 10.0, *)
public class MCAssetExportSession: NSObject {

    var delegate: MCAssetExportSessionDelegate?

    var preset: MCAssetExportSessionPreset = .MCAssetExportSessionPreset240P
    
    var asset: AVAsset!

    var videoComposition: AVVideoComposition?

    var audioMix: AVAudioMix?

    var outputFileType: AVFileType!

    var outputURL: URL?

    var videoOutputSettings: [String: Any]?

    var videoSettings: [String: Any]?
    
    var audioSettings: [String: Any]?

    var timeRange: CMTimeRange!

    var shouldOptimizeForNetworkUse = false

    var metadata = [AVMetadataItem]()

    var error: Error!
    
    var cancelled: Bool!

    var status: AVAssetExportSession.Status? {
        switch self.writer.status {
        case .unknown:
            return .unknown
        case .writing:
            return .exporting
        case .failed:
            return .exporting
        case .completed:
            return .completed
        case .cancelled:
            return .cancelled
        default: return .unknown
        }
    }

    var estimatedExportSize: Float64? {
        var audioBitrate: Int = 0
        var videoBitrate: Int = 0
        
        if self.audioSettings != nil {
            audioBitrate = self.audioSettings?[AVEncoderBitRateKey] as! Int
        } else {
            if #available(iOS 10.0, *) {
                audioBitrate = MCAssetExportSession.mc_assetExportAudioConfig()[AVEncoderBitRateKey] as! Int
            } else {
                // Fallback on earlier versions
            }
        }
        
        if self.videoSettings != nil {
            videoBitrate = (self.audioSettings?[AVVideoCompressionPropertiesKey] as! [String: Any])[AVVideoAverageBitRateKey] as! Int
        } else {
            let videoTracks = self.asset.tracks(withMediaType: .video)
            if videoTracks.count > 0 {
                let videoTrack = videoTracks[0]
                if #available(iOS 11.0, *) {
                    videoBitrate = (MCAssetExportSession.mc_assetExportVideoConfig(size: videoTrack.naturalSize, preset: preset)[AVVideoCompressionPropertiesKey] as! [String: Any]) [AVVideoAverageBitRateKey] as! Int
                } else {
                    // Fallback on earlier versions
                }
            }
        }
        
        var duration:Float64 = 0
        if CMTIME_IS_VALID(self.timeRange.duration) && !CMTIME_IS_POSITIVEINFINITY(self.timeRange.duration) {
            duration = CMTimeGetSeconds(self.timeRange.duration)
        } else {
            duration = CMTimeGetSeconds(self.asset.duration)
        }
        
        if audioBitrate > 0 && videoBitrate > 0 {
            let bitrate1 = Float64(audioBitrate) / 1000.0 / 8.0
            let bitrate2 = Float64(videoBitrate) / 1000.0 / 8.0
            let bitrate = bitrate1 + bitrate2
            let compressedSize = Float64(bitrate * duration)
            return compressedSize
        }
        
        return 0
    }
    
    private var audioQueue: DispatchQueue!
    private var videoQueue: DispatchQueue!
    private var dispatchGroup: DispatchGroup!
    
    var progress = 0.0
    private var reader: AVAssetReader!
    private var videoOutput: AVAssetReaderOutput!
    private var audioOutput: AVAssetReaderOutput!
    private var writer: AVAssetWriter!
    private var videoInput: AVAssetWriterInput!
    private var videoPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor!
    private var audioInput: AVAssetWriterInput!
    private var inputBufferSize: CGSize!
    private var videoOrientation = 0
    private var needsLeaveAudio = false
    private var needsLeaveVideo = false
    private var totalDuration: Float64 = 0
    var completionHandler: (() -> Void)?
    
    init(asset: AVAsset, preset: MCAssetExportSessionPreset) {
        
        audioQueue = DispatchQueue(label: "me.corsin.SCAssetExportSession.AudioQueue")
        videoQueue = DispatchQueue(label: "me.corsin.SCAssetExportSession.VideoQueue")
        dispatchGroup = DispatchGroup()
        timeRange = CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity)
        shouldOptimizeForNetworkUse = false
        
        self.asset = asset
        self.preset = preset
        self.videoOrientation = asset.mc_degressFromVideo()
        
        super.init()
    }
    
    func exportAsynchronouslyWithCompletionHandler(handler: @escaping () -> ()) {
        
        cancelled = false
        
        if self.outputURL == nil {
            error = NSError(domain: AVFoundationErrorDomain, code: -11820, userInfo: [NSLocalizedDescriptionKey : "Output URL not set"])
            handler()
            return
        }
        if FileManager.default.fileExists(atPath: self.outputURL!.path) {
            try! FileManager.default.removeItem(at: self.outputURL!)
        }
        
        do {
            let reader = try AVAssetReader.init(asset: self.asset)
            self.reader = reader
        } catch let readerError as Error? {
            error = readerError
            handler()
            return
        }
        
        do {
            let writer = try AVAssetWriter.init(url: self.outputURL!, fileType: self.outputFileType)
            self.writer = writer
        } catch let writerError as Error? {
            error = writerError
            handler()
            return
        }
        
        self.completionHandler = handler
        
        if CMTIME_IS_VALID(self.timeRange.duration) && !CMTIME_IS_POSITIVEINFINITY(self.timeRange.duration) {
            totalDuration = CMTimeGetSeconds(self.timeRange.duration)
        } else {
            totalDuration = CMTimeGetSeconds(self.asset.duration)
        }
            
        self.reader.timeRange = self.timeRange
        self.writer.shouldOptimizeForNetworkUse = self.shouldOptimizeForNetworkUse
        self.writer.metadata = self.metadata
        
        self.setupAudioUsingTracks(audioTracks: asset.tracks(withMediaType: AVMediaType.audio))
        self.setupVideoUsingTracks(videoTracks: asset.tracks(withMediaType: AVMediaType.video))
        
        if !reader.startReading() {
            error = reader.error
            handler()
            return
        }
        
        if !writer.startWriting() {
            error = writer.error
            handler()
            return
        }
        
        self.writer.startSession(atSourceTime: self.timeRange.start)
        
        self.beginReadWriteOnAudio()
        self.beginReadWriteOnVideo()
        
        dispatchGroup.notify(queue: DispatchQueue.main) {
            if self.error == nil {
                self.error = self.writer.error
            }
            if self.error == nil && self.writer.status != .cancelled {
                self.writer.finishWriting {
                    DispatchQueue.main.async {
                        self.error = self.writer.error
                        self.complete()
                    }
                }
            } else {
                self.complete()
            }
        }
    }
    
    @available(iOS 10.0, *)
    func setupAudioUsingTracks(audioTracks: [AVAssetTrack]) {
        //Audio output
        if audioTracks.count > 0 {
            let settings = MCAssetExportSession.mc_assetExportAudioOutputConfig()
            let audioMix = self.audioMix
            var audioOutput: AVAssetReaderOutput?
            if audioMix == nil {
                audioOutput = AVAssetReaderTrackOutput(track: audioTracks.first!, outputSettings: settings)
            } else {
                let audioMixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: settings)
                audioMixOutput.audioMix = audioMix
                audioOutput = audioMixOutput
            }
            audioOutput?.alwaysCopiesSampleData = false
            if self.reader.canAdd(audioOutput!) {
                self.reader.add(audioOutput!)
                self.audioOutput = audioOutput
            }
        } else {
            self.audioOutput = nil
        }
        // Audio input
        if self.audioInput != nil {
            var settings = self.audioSettings
            if settings == nil {
                settings = MCAssetExportSession.mc_assetExportAudioConfig()
            }
            
            self.audioInput = AVAssetWriterInput.init(mediaType: AVMediaType.audio, outputSettings: settings!)
            self.audioInput.expectsMediaDataInRealTime = false
            if self.writer.canAdd(self.audioInput) {
                self.writer.add(self.audioInput)
            }
        }
    }
    
    func setupVideoUsingTracks(videoTracks: [AVAssetTrack]) {
        // Video output
        if videoTracks.count > 0 {
            let videoTrack = videoTracks.first!
            
            var videoComposition = self.videoComposition
            
            if videoComposition == nil {
                videoComposition = self.buildDefaultVideoComposition()
            }
            
            if videoComposition == nil {
                inputBufferSize = videoTrack.naturalSize
            } else {
                inputBufferSize = videoComposition?.renderSize
            }
            
            var settings = videoOutputSettings
            if settings == nil {
                settings = MCAssetExportSession.mc_assetExportVideoOutputConfig()
            }
            
            var videoOutput: AVAssetReaderOutput?
            if videoComposition == nil {
                videoOutput = AVAssetReaderTrackOutput.init(track: videoTrack, outputSettings: settings)
            } else {
                let videoCompositionOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: settings)
                videoCompositionOutput.videoComposition = videoComposition
                videoOutput = videoCompositionOutput
            }
            videoOutput?.alwaysCopiesSampleData = false
            
            if reader.canAdd(videoOutput!) {
                reader.add(videoOutput!)
                self.videoOutput = videoOutput
            }
        } else {
            self.videoOutput = nil
        }
        // Video input
        if self.videoOutput != nil {
            var videoSettings = self.videoSettings
            if videoSettings == nil {
                if #available(iOS 11.0, *) {
                    videoSettings = MCAssetExportSession.mc_assetExportVideoConfig(size: inputBufferSize, preset: preset)
                } else {
                    // Fallback on earlier versions
                }
            }
            let videoInput = AVAssetWriterInput.init(mediaType: .video, outputSettings: videoSettings!)
            videoInput.expectsMediaDataInRealTime = false
            if writer.canAdd(videoInput) {
                writer.add(videoInput)
                self.videoInput = videoInput
            }
            
            if self.videoInput != nil {
                let pixelBufferAttributes = [
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey: self.inputBufferSize.width,
                    kCVPixelBufferHeightKey: self.inputBufferSize.height,
                    kCVPixelFormatOpenGLESCompatibility: true
                ] as [String : Any]
                self.videoPixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: self.videoInput, sourcePixelBufferAttributes: pixelBufferAttributes)
            }
        }
    }
    
    func beginReadWriteOnAudio() {
        if audioInput != nil {
            dispatchGroup.enter()
            needsLeaveAudio = true
            // [weak self] in
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                var shouldReadNextBuffer = true
                while self.audioInput.isReadyForMoreMediaData && shouldReadNextBuffer && !self.cancelled {
                    let audioBuffer = self.audioInput.copy() as! CMSampleBuffer
                    
                    shouldReadNextBuffer = self.audioInput.append(audioBuffer)
                    let time = CMSampleBufferGetPresentationTimeStamp(audioBuffer)
                    
                    self.didAppendToInput(input: self.audioInput, time: time)
                }
                if !shouldReadNextBuffer {
                    self.markInputComplete(input: self.audioInput, error: nil)
                    if self.needsLeaveAudio {
                        self.needsLeaveAudio = false
                        self.dispatchGroup.leave()
                    }
                }
            }
        }
    }
    
    func beginReadWriteOnVideo() {
        if videoInput != nil {
            dispatchGroup.enter()
            needsLeaveVideo = true
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                var shouldReadNextBuffer = true
                while self.videoInput.isReadyForMoreMediaData && shouldReadNextBuffer && !self.cancelled {
                    let videoBuffer = self.videoOutput.copyNextSampleBuffer()
                    if videoBuffer != nil {
                        var time = CMSampleBufferGetPresentationTimeStamp(videoBuffer!)
                        time = CMTimeSubtract(time, self.timeRange.start)
                        
                        var renderBuffer: CVPixelBuffer? = nil
                        
                        let pixelBuffer = CMSampleBufferGetImageBuffer(videoBuffer!)
                        
                        let status = CVPixelBufferPoolCreatePixelBuffer(nil, self.videoPixelBufferAdaptor.pixelBufferPool!, &renderBuffer)

                        if status == kCVReturnSuccess {
                            self.delegate?.assetExportSession(self, pixelBuffer!, time, renderBuffer!)
                        } else {
                            print("Failed to create pixel buffer")
                        }
                        
                        if renderBuffer != nil {
                            shouldReadNextBuffer = self.videoPixelBufferAdaptor.append(renderBuffer!, withPresentationTime: time)
                        } else {
                            shouldReadNextBuffer = self.videoInput.append(videoBuffer!)
                        }
                        
                        self.didAppendToInput(input: self.videoInput, time: time)
                        
                    } else {
                        shouldReadNextBuffer = false
                    }
                }
                if !shouldReadNextBuffer {
                    self.markInputComplete(input: self.videoInput, error: nil)
                    
                    if self.needsLeaveVideo {
                        self.needsLeaveVideo = false
                        self.dispatchGroup.leave()
                    }
                }
            }
        }
    }
    
    func markInputComplete(input: AVAssetWriterInput, error: Error?) {
        if reader.status == .failed {
            self.error = reader.error
        } else {
            self.error = error
        }
        if writer.status == .cancelled {
            input.markAsFinished()
        }
    }
    
    func didAppendToInput(input: AVAssetWriterInput, time: CMTime) {
        if input == videoInput || videoInput == nil {
            let progress = totalDuration == 0 ? 1 : CMTimeGetSeconds(time) / totalDuration
            self.setProgress(progress: progress)
        }
    }
    
    func buildDefaultVideoComposition() -> (AVMutableVideoComposition?) {
        let videoComposition = self.fixedCompositionWithAsset(videoAsset: asset)
        if videoComposition != nil {
            let videoTrack = asset.tracks(withMediaType: .video).first!
            var trackFrameRate:CGFloat = 0
            if videoSettings != nil {
                let videoCompressionProperties = videoSettings![AVVideoCompressionPropertiesKey] as? NSDictionary
                if videoCompressionProperties != nil {
                    let frameRate = videoCompressionProperties![AVVideoAverageNonDroppableFrameRateKey]
                    if frameRate != nil {
                        trackFrameRate = frameRate as! CGFloat
                    }
                }
            } else {
                trackFrameRate = CGFloat(videoTrack.nominalFrameRate)
            }
            
            if trackFrameRate == 0 {
                trackFrameRate = 30
            }
            videoComposition!.frameDuration = CMTimeMake(1, Int32(trackFrameRate))
        }
        return videoComposition
    }
    /// 获取优化后的视频转向信息
    func fixedCompositionWithAsset(videoAsset: AVAsset) -> (AVMutableVideoComposition?) {
        var videoComposition: AVMutableVideoComposition?
        
        let degrees = self.videoOrientation
        if degrees != 0 {
            videoComposition = AVMutableVideoComposition()
            
            var translateToCenter: CGAffineTransform
            var mixedTransform: CGAffineTransform
            
            let tracks = videoAsset.tracks(withMediaType: .video)
            let videoTrack = tracks.first
            
            let roateInstruction = AVMutableVideoCompositionInstruction()
            roateInstruction.timeRange = CMTimeRangeMake(kCMTimeZero, videoAsset.duration)
            let roateLayerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack!)
            
            if degrees == 90 {
                // 顺时针90°
                translateToCenter = CGAffineTransform(translationX: videoTrack!.naturalSize.height, y: 0.0)
                mixedTransform = translateToCenter.rotated(by: .pi / 2)
                videoComposition?.renderSize = CGSize(width: videoTrack!.naturalSize.height, height: videoTrack!.naturalSize.width)
                roateLayerInstruction.setTransform(mixedTransform, at: kCMTimeZero)
            } else if degrees == 180 {
                // 顺时针180°
                translateToCenter = CGAffineTransform(translationX: videoTrack!.naturalSize.width, y: videoTrack!.naturalSize.height)
                mixedTransform = translateToCenter.rotated(by: .pi)
                videoComposition?.renderSize = CGSize(width: videoTrack!.naturalSize.width, height: videoTrack!.naturalSize.height)
                roateLayerInstruction.setTransform(mixedTransform, at: kCMTimeZero)
            } else if degrees == 270 {
                // 顺时针270°
                translateToCenter = CGAffineTransform(translationX: 0, y: videoTrack!.naturalSize.width)
                mixedTransform = translateToCenter.rotated(by: .pi / 2 * 3)
                videoComposition?.renderSize = CGSize(width: videoTrack!.naturalSize.height, height: videoTrack!.naturalSize.width)
                roateLayerInstruction.setTransform(mixedTransform, at: kCMTimeZero)
            } else {
                videoComposition?.renderSize = CGSize(width: videoTrack!.naturalSize.width, height: videoTrack!.naturalSize.height)
            }
            roateInstruction.layerInstructions = [roateLayerInstruction]
            videoComposition?.instructions = [roateInstruction]
        }
        return videoComposition
    }
    
    func complete() {
        if !cancelled {
            self.setProgress(progress: 1)
        }
        
        if self.writer.status == .failed || self.writer.status == .cancelled {
            try! FileManager.default.removeItem(at: self.outputURL!)
        }
        
        if completionHandler != nil {
            self.completionHandler!()
            self.completionHandler = nil
        }
        self.reset()
    }
    
    func cancelExport() {
        cancelled = true
        
        videoQueue.sync {
            if needsLeaveVideo {
                needsLeaveVideo = false
                dispatchGroup.leave()
            }
            
            self.audioQueue.sync {
                if needsLeaveAudio {
                    needsLeaveAudio = false
                    dispatchGroup.leave()
                }
            }
            
            self.reader.cancelReading()
            self.writer.cancelWriting()
        }
    }
    
    func setProgress(progress: Double) {
        
        let doProgress = {
            self.willChangeValue(forKey: "progress")
            self.progress = progress
            self.didChangeValue(forKey: "progress")
            
            self.delegate?.assetExportSessionDidProgress(assetExportSession: self)
        }
        
        if Thread.isMainThread {
            doProgress()
        } else {
            DispatchQueue.main.async {
                doProgress()
            }
        }
    }
    
    func reset() {
        error = nil
        progress = 0
        inputBufferSize = .zero
        reader = nil
        videoOutput = nil
        audioOutput = nil
        writer = nil
        videoInput = nil
        videoPixelBufferAdaptor = nil
        audioInput = nil
        completionHandler = nil
    }
}

@available(iOS 10.0, *)
extension MCAssetExportSession {
    static func mc_assetExportSessionPresetSize(preset: MCAssetExportSessionPreset) -> CGSize {
        var size = CGSize()
        switch preset {
        case .MCAssetExportSessionPreset240P:
            size = CGSize(width: 240, height: 360)
        case .MCAssetExportSessionPreset360P:
            size = CGSize(width: 360, height: 480)
        case .MCAssetExportSessionPreset480P:
            size = CGSize(width: 480, height: 640)
        case .MCAssetExportSessionPreset540P:
            size = CGSize(width: 540, height: 960)
        case .MCAssetExportSessionPreset720P:
            size = CGSize(width: 720, height: 1280)
        case .MCAssetExportSessionPreset1080P:
            size = CGSize(width: 1080, height: 1920)
        case .MCAssetExportSessionPreset2K:
            size = CGSize(width: 1440, height: 2560)
        case .MCAssetExportSessionPreset4K:
            size = CGSize(width: 2160, height: 3840)
        }
        return size
    }
    
    static func mc_assetExportSessionPresetFromSize(size: inout CGSize) -> MCAssetExportSessionPreset {
        
        if size.width > size.height {
            let w = size.width
            size.width = size.height
            size.height = w
        }
        
        if size.width <= 240 && size.height <= 360 {
            return .MCAssetExportSessionPreset240P
        }
        if size.width <= 360 && size.height <= 480 {
            return .MCAssetExportSessionPreset240P
        }
        if size.width <= 480 && size.height <= 640 {
            return .MCAssetExportSessionPreset240P
        }
        if size.width <= 540 && size.height <= 960 {
            return .MCAssetExportSessionPreset240P
        }
        if size.width <= 720 && size.height <= 1280 {
            return .MCAssetExportSessionPreset240P
        }
        if size.width <= 1440 && size.height <= 2560 {
            return .MCAssetExportSessionPreset240P
        }
        if size.width <= 2160 && size.height <= 3480 {
            return .MCAssetExportSessionPreset240P
        }
        return .MCAssetExportSessionPreset240P
    }
    
    static func mc_assetExportSessionPresetBitrate(preset: MCAssetExportSessionPreset) -> Int {
        
        var bitrate: Int = 0
        switch preset {
        case .MCAssetExportSessionPreset240P:
            bitrate = 450000
        case .MCAssetExportSessionPreset360P:
            bitrate = 770000
        case .MCAssetExportSessionPreset480P:
            bitrate = 1200000
        case .MCAssetExportSessionPreset540P:
            bitrate = 2074000
        case .MCAssetExportSessionPreset720P:
            bitrate = 3500000
        case .MCAssetExportSessionPreset1080P:
            bitrate = 7900000
        case .MCAssetExportSessionPreset2K:
            bitrate = 13000000
        case .MCAssetExportSessionPreset4K:
            bitrate = 35000000
        }
        return bitrate
    }
    
    @available(iOS 11.0, *)
    static func mc_assetExportVideoConfig(size: CGSize, preset: MCAssetExportSessionPreset) -> [String : Any] {
        var ratio:CGFloat = 1
        let presetSize = mc_assetExportSessionPresetSize(preset: preset)
        var videoSize = size
        if videoSize.width > videoSize.height {
            ratio = videoSize.width / presetSize.height
        } else {
            ratio = videoSize.width / presetSize.width
        }
        
        if ratio > 1 {
            videoSize = CGSize(width: videoSize.width / ratio, height: videoSize.height / ratio)
        }
        
        let realPreset = mc_assetExportSessionPresetFromSize(size: &videoSize)
        let bitrate = mc_assetExportSessionPresetBitrate(preset: realPreset)
        
        let videoCompressionProperties = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoExpectedSourceFrameRateKey: 30,
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2
        ] as [String : Any]
        
        if #available(iOS 11.0, *) {
            let reluslt = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: videoSize.width,
                AVVideoHeightKey: videoSize.height,
                AVVideoScalingModeKey:AVVideoScalingModeResizeAspectFill,
                AVVideoCompressionPropertiesKey: videoCompressionProperties
            ] as [String : Any]
            return reluslt
        } else {
            // Fallback on earlier versions
            let reluslt = [
                AVVideoWidthKey: videoSize.width,
                AVVideoHeightKey: videoSize.height,
                AVVideoScalingModeKey:AVVideoScalingModeResizeAspectFill,
                AVVideoCompressionPropertiesKey: videoCompressionProperties
            ] as [String : Any]
            return reluslt
        }
        
    }
    
    static func mc_assetExportVideoOutputConfig() -> [String : Any] {
        let result = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()
        ] as [String : Any]
        return result
    }
    
    static func mc_assetExportAudioOutputConfig() -> [String : Any] {
        let result = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ] as [String : Any]
        return result
    }
    
    static func mc_assetExportAudioConfig() -> [String : Any] {
        var channelLayout = AudioChannelLayout()
        memset(&channelLayout, 0, MemoryLayout<AudioChannelLayout>.size)
        channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let result = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVChannelLayoutKey: NSData(bytes: &channelLayout, length: MemoryLayout<AudioChannelLayout>.size),
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 128000
        ] as [String : Any]
        return result
    }
}

extension AVAsset {
    
    func mc_degressFromVideo() -> Int {
        var degress = 0
        let tracks = self.tracks(withMediaType: .video)
        if tracks.count > 0 {
            let videoTrack = tracks[0]
            let t = videoTrack.preferredTransform
            if t.a == 0 && t.b == 1.0 && t.c == -1.0 && t.d == 0 {
                degress = 90
            } else if t.a == 0 && t.b == -1.0 && t.c == 1.0 && t.d == 0 {
                degress = 270
            } else if t.a == 1.0 && t.b == 0 && t.c == 0 && t.d == 1.0 {
                degress = 0
            } else if t.a == -1.0 && t.b == 0 && t.c == 0 && t.d == -1.0 {
                degress = 180
            }
        }
        return degress
    }

}

