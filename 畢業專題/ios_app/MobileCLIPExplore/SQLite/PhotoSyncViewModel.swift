import Foundation
import Photos
import CoreML
import UIKit
import CoreLocation

struct BackgroundSyncSummary {
    let embeddedCount: Int
    let classifiedCount: Int
}

class PhotoSyncViewModel: ObservableObject {
    private static let executionStateQueue = DispatchQueue(label: "com.photoai.sync.execution")
    private static var isAnySyncRunning = false
    
    @Published var isSyncing = false
    @Published var syncedCount = 0
    @Published var totalCount = 0
    
    // 🌟 新增：用於控制暫停的標記
    private var isCancelled = false
    
    private let imageModel = try? mobileclip_s2_image(configuration: MLModelConfiguration())
    private let geocoder = CLGeocoder()
    private let classificationQueue = DispatchQueue(label: "com.photoai.classification.worker", qos: .utility)
    private let classificationStateQueue = DispatchQueue(label: "com.photoai.classification.state")
    private let classificationBatchSize = 50
    private let metadataFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private var isScanningEmbeddings = false
    private var classifiedCountDuringCurrentSync = 0

    // 🌟 新增：由 UI 呼叫的暫停函數
    func stopSync() {
        print("使用者要求暫停同步")
        isCancelled = true
    }

    func startSync() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            guard status == .authorized || status == .limited else {
                print("未取得相簿權限")
                return
            }

            guard let self, self.beginSyncExecution() else {
                print("同步略過：已有其他同步任務正在執行")
                return
            }
            
            DispatchQueue.main.async {
                self.isSyncing = true
                self.isCancelled = false // 🌟 開始同步時重置暫停標記
                self.fetchAndProcessPhotos()
            }
        }
    }

    func performBackgroundSync(
        scanLimit: Int = 20,
        classificationLimit: Int = 50,
        shouldContinue: @escaping () -> Bool = { true }
    ) -> BackgroundSyncSummary {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            print("背景同步略過：未取得相簿權限")
            return BackgroundSyncSummary(embeddedCount: 0, classifiedCount: 0)
        }

        guard beginSyncExecution() else {
            print("背景同步略過：已有其他同步任務正在執行")
            return BackgroundSyncSummary(embeddedCount: 0, classifiedCount: 0)
        }
        defer { endSyncExecution() }

        let assets = fetchUnscannedAssets(limit: scanLimit)
        guard shouldContinue() else {
            return BackgroundSyncSummary(embeddedCount: 0, classifiedCount: 0)
        }

        var embeddedCount = 0
        for asset in assets {
            guard shouldContinue() else { break }
            if processAssetForEmbedding(asset, shouldReverseGeocode: false) {
                embeddedCount += 1
            }
        }

        let classifiedCount = shouldContinue()
            ? DatabaseManager.shared.classifyPendingPhotos(limit: classificationLimit)
            : 0

        return BackgroundSyncSummary(
            embeddedCount: embeddedCount,
            classifiedCount: classifiedCount
        )
    }
    
    private func fetchAndProcessPhotos() {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        // 🌟 新增：強制只抓取最新的 1000 張照片
        fetchOptions.fetchLimit = 10
        
        let allAssets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        
        let scannedIds = DatabaseManager.shared.fetchAllScannedAssetIds()
        
        var unscannedAssets: [PHAsset] = []
        allAssets.enumerateObjects { (asset, _, _) in
            if !scannedIds.contains(asset.localIdentifier) {
                unscannedAssets.append(asset)
            }
        }
        
        guard !unscannedAssets.isEmpty else {
            let classifiedCount = self.drainPendingClassifications()
            self.backfillMissingLocationMetadata(limit: 25)
            DispatchQueue.main.async {
                self.isSyncing = false
                print("所有照片都已是最新的，無需掃描。補做分類 \(classifiedCount) 張。")
            }
            self.endSyncExecution()
            return
        }

        DispatchQueue.main.async {
            self.totalCount = unscannedAssets.count
            self.syncedCount = 0
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.endSyncExecution() }

            self.startClassificationWorker()

            for asset in unscannedAssets {
                // 🌟 新增：每個迴圈檢查是否被暫停
                if self.isCancelled {
                    print("同步已中斷")
                    break
                }
                
                if self.processAssetForEmbedding(asset) {
                    DispatchQueue.main.async { self.syncedCount += 1 }
                }
            }

            let classifiedCount = self.finishClassificationWorkerAndWait()
            self.backfillMissingLocationMetadata(limit: 25)
            
            DispatchQueue.main.async {
                self.isSyncing = false
                print("掃描任務結束！共新增處理 \(self.syncedCount) 張照片，完成分類 \(classifiedCount) 張。")
            }
        }
    }
    
    private func requestPixelBuffer(for asset: PHAsset, completion: @escaping (CVPixelBuffer?) -> Void) {
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        
        let targetSize = CGSize(width: 256, height: 256)
        
        manager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { image, _ in
            guard let uiImage = image, let cgImage = uiImage.cgImage else {
                completion(nil)
                return
            }
            let pixelBuffer = self.pixelBuffer(from: cgImage, size: targetSize)
            completion(pixelBuffer)
        }
    }
    
    private func pixelBuffer(from image: CGImage, size: CGSize) -> CVPixelBuffer? {
        let options: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        var pxbuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(size.width),
                                         Int(size.height),
                                         kCVPixelFormatType_32ARGB,
                                         options as CFDictionary,
                                         &pxbuffer)
        
        guard status == kCVReturnSuccess, let buffer = pxbuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, .init(rawValue: 0))
        let pxdata = CVPixelBufferGetBaseAddress(buffer)
        
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: pxdata,
                                width: Int(size.width),
                                height: Int(size.height),
                                bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: rgbColorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        
        context?.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        CVPixelBufferUnlockBaseAddress(buffer, .init(rawValue: 0))
        
        return buffer
    }

    private func enrichLocationMetadataIfNeeded(assetId: String, location: CLLocation) {
        geocoder.reverseGeocodeLocation(location) { placemarks, error in
            guard error == nil else { return }
            guard let placemark = placemarks?.first else { return }

            let locationParts = [
                placemark.name,
                placemark.locality,
                placemark.subLocality,
                placemark.administrativeArea,
                placemark.country
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

            guard !locationParts.isEmpty else { return }

            let locationText = Array(NSOrderedSet(array: locationParts)).compactMap { $0 as? String }.joined(separator: ", ")
            DatabaseManager.shared.updatePhotoMetadata(assetId: assetId, merge: [
                "locationText": locationText
            ])
        }
    }

    private func backfillMissingLocationMetadata(limit: Int) {
        let assetIds = DatabaseManager.shared.fetchAssetIdsNeedingLocationMetadata(limit: limit)
        guard !assetIds.isEmpty else { return }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil)
        fetchResult.enumerateObjects { asset, _, _ in
            guard let location = asset.location else { return }
            self.enrichLocationMetadataIfNeeded(assetId: asset.localIdentifier, location: location)
        }
    }

    private func fetchUnscannedAssets(limit: Int? = nil) -> [PHAsset] {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        // 🌟 確保背景同步也只針對最新照片做檢查
        fetchOptions.fetchLimit = 1000
        
        let allAssets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        let scannedIds = DatabaseManager.shared.fetchAllScannedAssetIds()

        var unscannedAssets: [PHAsset] = []
        allAssets.enumerateObjects { asset, _, stop in
            guard !scannedIds.contains(asset.localIdentifier) else { return }
            unscannedAssets.append(asset)

            if let limit, unscannedAssets.count >= limit {
                stop.pointee = true
            }
        }
        return unscannedAssets
    }

    private func processAssetForEmbedding(_ asset: PHAsset, shouldReverseGeocode: Bool = true) -> Bool {
        let assetId = asset.localIdentifier
        let metadata = metadataJSONString(for: asset)
        var didProcess = false

        let semaphore = DispatchSemaphore(value: 0)
        requestPixelBuffer(for: asset) { pixelBuffer in
            defer { semaphore.signal() }
            guard let pixelBuffer = pixelBuffer, let model = self.imageModel else { return }

            do {
                let input = mobileclip_s2_imageInput(image: pixelBuffer)
                let prediction = try model.prediction(input: input)
                let rawEmbedding = prediction.final_emb_1
                let normalizedArray = rawEmbedding.toFloatArray().normalized()
                let embeddingData = Data(buffer: UnsafeBufferPointer(start: normalizedArray, count: normalizedArray.count))

                DatabaseManager.shared.insertPhotoEmbedding(
                    assetId: assetId,
                    metadata: metadata,
                    embeddingData: embeddingData
                )

                if shouldReverseGeocode, let location = asset.location {
                    self.enrichLocationMetadataIfNeeded(assetId: assetId, location: location)
                }

                didProcess = true
            } catch {
                print("照片 \(assetId) 推論失敗：\(error)")
            }
        }
        semaphore.wait()
        return didProcess
    }

    private func metadataJSONString(for asset: PHAsset) -> String {
        var metadataDict: [String: Any] = [:]
        if let date = asset.creationDate {
            metadataDict["date"] = date.description
            metadataDict["dayKey"] = metadataFormatter.string(from: date)
        }
        if let location = asset.location {
            metadataDict["latitude"] = location.coordinate.latitude
            metadataDict["longitude"] = location.coordinate.longitude
            metadataDict["coordinateText"] = String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude)
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: metadataDict),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }
        return "{}"
    }

    private func startClassificationWorker() {
        classificationStateQueue.sync {
            isScanningEmbeddings = true
            classifiedCountDuringCurrentSync = 0
        }

        classificationQueue.async {
            DatabaseManager.shared.prepareClassificationIfNeeded()

            while true {
                // 🌟 新增：背景分類也檢查是否被使用者取消
                if self.isCancelled { break }
                
                let classified = DatabaseManager.shared.classifyPendingPhotos(limit: self.classificationBatchSize)
                if classified > 0 {
                    self.classificationStateQueue.sync {
                        self.classifiedCountDuringCurrentSync += classified
                    }
                    continue
                }

                let stillScanning = self.classificationStateQueue.sync { self.isScanningEmbeddings }
                if !stillScanning {
                    break
                }

                Thread.sleep(forTimeInterval: 0.15)
            }

            while true {
                if self.isCancelled { break }
                let classified = DatabaseManager.shared.classifyPendingPhotos(limit: self.classificationBatchSize)
                guard classified > 0 else { break }
                self.classificationStateQueue.sync {
                    self.classifiedCountDuringCurrentSync += classified
                }
            }
        }
    }

    private func drainPendingClassifications() -> Int {
        DatabaseManager.shared.prepareClassificationIfNeeded()

        var total = 0
        while true {
            if self.isCancelled { break }
            let classified = DatabaseManager.shared.classifyPendingPhotos(limit: classificationBatchSize)
            guard classified > 0 else { break }
            total += classified
        }
        return total
    }

    private func finishClassificationWorkerAndWait() -> Int {
        classificationStateQueue.sync {
            isScanningEmbeddings = false
        }

        classificationQueue.sync { }

        return classificationStateQueue.sync {
            let total = classifiedCountDuringCurrentSync
            classifiedCountDuringCurrentSync = 0
            return total
        }
    }

    private func beginSyncExecution() -> Bool {
        Self.executionStateQueue.sync {
            guard !Self.isAnySyncRunning else { return false }
            Self.isAnySyncRunning = true
            return true
        }
    }

    private func endSyncExecution() {
        Self.executionStateQueue.sync {
            Self.isAnySyncRunning = false
        }
    }
}
