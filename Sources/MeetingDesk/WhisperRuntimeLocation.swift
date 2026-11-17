import CryptoKit
import Foundation

enum WhisperRuntimeLocation {
    static let isBundled: Bool = {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("ASRRuntime") else { return false }
        return FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("python/bin/python3.12").path)
    }()

    static func launch(bundle: Bundle = .main) throws -> WhisperWorkerLaunch {
        guard let root = bundle.resourceURL?.appendingPathComponent("ASRRuntime").resolvingSymlinksInPath() else {
            throw WhisperAdapterFailure.runtimeUnavailable
        }
        let python = root.appendingPathComponent("python/bin/python3.12")
        let worker = root.appendingPathComponent("worker.py")
        let manifestURL = root.appendingPathComponent("runtime-manifest.json")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              let size = try FileManager.default.attributesOfItem(atPath: worker.path)[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= 262_144,
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
              let expected = manifest["workerSHA256"] as? String,
              expected == SHA256.hash(data: try Data(contentsOf: worker)).map({ String(format: "%02x", $0) }).joined() else {
            throw WhisperAdapterFailure.runtimeUnavailable
        }
        return WhisperWorkerLaunch(pythonExecutable: python, workerScript: worker)
    }
}
