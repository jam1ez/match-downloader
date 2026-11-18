import Foundation
import Vision
for file in CommandLine.arguments.dropFirst() {
    autoreleasepool {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.008
        do {
            try VNImageRequestHandler(url: URL(fileURLWithPath:file)).perform([request])
            let rows: [[String:Any]] = (request.results ?? []).compactMap { row in
                guard let text = row.topCandidates(1).first else { return nil }
                let b=row.boundingBox
                return ["text":text.string,"confidence":text.confidence,"x":b.minX,"y":1-b.maxY,"w":b.width,"h":b.height]
            }
            let value:[String:Any] = ["file":file,"rows":rows]
            let data = try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
            print(String(data:data,encoding:.utf8)!)
        } catch {
            let data=try! JSONSerialization.data(withJSONObject:["file":file,"error":error.localizedDescription])
            print(String(data:data,encoding:.utf8)!)
        }
    }
}
