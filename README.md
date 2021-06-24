# MCAssetExportSession

[![CI Status](https://img.shields.io/travis/dongxiao/MCAssetExportSession.svg?style=flat)](https://travis-ci.org/dongxiao/MCAssetExportSession)
[![Version](https://img.shields.io/cocoapods/v/MCAssetExportSession.svg?style=flat)](https://cocoapods.org/pods/MCAssetExportSession)
[![License](https://img.shields.io/cocoapods/l/MCAssetExportSession.svg?style=flat)](https://cocoapods.org/pods/MCAssetExportSession)
[![Platform](https://img.shields.io/cocoapods/p/MCAssetExportSession.svg?style=flat)](https://cocoapods.org/pods/MCAssetExportSession)

## Example

To run the example project, clone the repo, and run `pod install` from the Example directory first.

示例代码

func encodeVideoWithURL(videoURL: URL) {
    let asset = AVURLAsset(url: videoURL)
    let outPath = URL(fileURLWithPath: self.createFile(name: self.fileName()))
    encoder = MCAssetExportSession(asset: asset, preset: .MCAssetExportSessionPreset720P)
    encoder.delegate = self
    encoder.outputFileType = AVFileType.mp4
    encoder.outputURL = outPath
    
    print("The compressed file size is about \(encoder.estimatedExportSize!/1000.0)MB")
    
    encoder.exportAsynchronouslyWithCompletionHandler {
        if self.encoder.status == .completed {
            print("Video export succeeded. video path: \(self.encoder.outputURL!)")
            print("video size\(String(describing: self.encoder.outputURL?.relativePath.mc_fileSize))")
            ///1024.0/1024.0
        } else if self.encoder.status == .cancelled {
            print("export cancel")
        } else {
            print("export failed \(String(describing: self.encoder.error))")
        }
    }
    
    // MCAssetExportSessionDelegate
    func assetExportSession(_ assetExportSession: MCAssetExportSession, _ renderFrame: CVPixelBuffer, _ withPresentationTime: CMTime, _ toBuffer: CVPixelBuffer) {
        
    }

    func assetExportSessionDidProgress(assetExportSession: MCAssetExportSession) {
        print("progress==\(assetExportSession.progress)")
    }



## Requirements

## Installation

MCAssetExportSession is available through [CocoaPods](https://cocoapods.org). To install
it, simply add the following line to your Podfile:

```ruby
pod 'MCAssetExportSession'
```

## Author

dongxiao, 734692659@qq.com, dx

## License

MCAssetExportSession is available under the MIT license. See the LICENSE file for more info.
