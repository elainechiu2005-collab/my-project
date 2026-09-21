import Foundation
import CoreML
import SQLite
import UIKit
import Accelerate
import CoreLocation
import Photos

// 🌟 用於記憶體的資料結構
struct CachedCategory {
    let clusterId: Int
    let keyword: String
    let parentCategory: String
    let embedding: [Float]
}

struct CachedParentCategory {
    let name: String
    let embedding: [Float]
    let children: [CachedCategory]
}

struct CustomAlbumSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let coverAssetId: String?
    let photoCount: Int
}

struct PhotoListItem: Identifiable, Hashable {
    let id: String
    let isFavorite: Bool
    let tag: String
    let date: String
}

struct MetadataAlbumSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let coverAssetId: String?
    let photoCount: Int
    let primaryAssetIds: [String]
    let otherAssetIds: [String]

    var assetIds: [String] {
        primaryAssetIds + otherAssetIds
    }

    var otherPhotoCount: Int {
        otherAssetIds.count
    }
}

struct MetadataAlbumSection: Identifiable, Hashable {
    let id: String
    let title: String
    let albums: [MetadataAlbumSummary]
}

class DatabaseManager {
    static let shared = DatabaseManager()
    private var db: Connection?
    
    // 🌟 全域快取陣列 (存放 1400 筆語意字典)
    private var categoryCache: [CachedCategory] = []
    private var parentCategoryCache: [CachedParentCategory] = []
    
    // 🌟 資料庫寫入序列化佇列 (防止多執行緒併發寫入時引發 Database Locked)
    private let writeQueue = DispatchQueue(label: "com.photoai.db.writeQueue")
    private let classificationPreparationQueue = DispatchQueue(label: "com.photoai.db.classificationPreparation")
    private let classificationThreshold: Float = 0.21
    private var hasPreparedClassification = false
    private lazy var textModel: mobileclip_s2_text? = {
        try? mobileclip_s2_text(configuration: MLModelConfiguration())
    }()
    private lazy var queryDateFormatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd", "yyyy/M/d", "yyyy/M/dd", "yyyy/MM/d", "yyyy/MM/dd",
            "M/d/yyyy", "MM/dd/yyyy", "d/M/yyyy", "dd/MM/yyyy",
            "yyyy年M月d日", "M月d日yyyy年", "MMM d, yyyy", "MMMM d, yyyy"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            return formatter
        }
    }()
    private let metadataDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private init() {
        copyDatabaseIfNeeded()
        connectDatabase()
        createNotesTableIfNeeded()
        createCustomAlbumTablesIfNeeded()
        syncBundledTaxonomyIfNeeded()
        loadDictionaryIntoMemory() // 啟動時一次性將字典讀入 RAM
    }
    
    // MARK: - 基礎連線設定
    private func copyDatabaseIfNeeded() {
        let fileManager = FileManager.default
        guard let documentsUrl = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let finalDatabaseURL = documentsUrl.appendingPathComponent("PhotoAI.sqlite")
        
        if !fileManager.fileExists(atPath: finalDatabaseURL.path) {
            if let bundleURL = Bundle.main.url(forResource: "PhotoAI", withExtension: "sqlite") {
                do {
                    try fileManager.copyItem(at: bundleURL, to: finalDatabaseURL)
                    print("資料庫複製成功")
                } catch { print("複製資料庫失敗: \(error)") }
            }
        }
    }
    
    private func connectDatabase() {
        guard let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let finalDatabaseURL = documentsUrl.appendingPathComponent("PhotoAI.sqlite")
        do {
            db = try Connection(finalDatabaseURL.path)
            print("成功連接 SQLite 資料庫")
        } catch { print("連接資料庫失敗: \(error)") }
    }

    private func syncBundledTaxonomyIfNeeded() {
        guard let db,
              let bundleURL = Bundle.main.url(forResource: "PhotoAI", withExtension: "sqlite")
        else { return }

        do {
            let bundledDB = try Connection(bundleURL.path)
            let bundledCount = (try bundledDB.scalar("SELECT COUNT(*) FROM ClusterSummary") as? Int64) ?? 0
            let currentCount = (try db.scalar("SELECT COUNT(*) FROM ClusterSummary") as? Int64) ?? 0

            guard bundledCount > currentCount else { return }

            var bundledCategories: [(keyword: String, parentCategory: String)] = []
            for row in try bundledDB.prepare("SELECT keyword, parent_category FROM ClusterSummary ORDER BY cluster_id ASC").run() {
                let keyword = row[0] as? String ?? ""
                let parentCategory = row[1] as? String ?? "Uncategorized"
                guard !keyword.isEmpty else { continue }
                bundledCategories.append((keyword: keyword, parentCategory: parentCategory))
            }

            try syncClusterSummary(with: bundledCategories)
            print("📦 已從 app 內建資料庫同步最新分類表：\(bundledCount) 筆小分類。")
        } catch {
            print("同步內建分類表失敗: \(error)")
        }
    }

    private func syncClusterSummary(with categories: [(keyword: String, parentCategory: String)]) throws {
        guard let db else { return }

        var existingKeywordMap: [String: Int64] = [:]
        for row in try db.prepare("SELECT cluster_id, keyword FROM ClusterSummary").run() {
            let clusterId = row[0] as? Int64 ?? 0
            let keyword = row[1] as? String ?? ""
            if !keyword.isEmpty {
                existingKeywordMap[keyword] = clusterId
            }
        }

        let importedKeywords = Set(categories.map(\.keyword))
        let removedKeywords = existingKeywordMap.keys.filter { !importedKeywords.contains($0) }

        try db.transaction {
            for category in categories {
                try db.prepare("""
                INSERT OR IGNORE INTO SemanticDictionary (keyword, word_embedding)
                VALUES (?, NULL)
                """).run(category.keyword)

                if existingKeywordMap[category.keyword] != nil {
                    try db.prepare("""
                    UPDATE ClusterSummary
                    SET parent_category = ?
                    WHERE keyword = ?
                    """).run(category.parentCategory, category.keyword)
                } else {
                    try db.prepare("""
                    INSERT INTO ClusterSummary (keyword, parent_category, random_vector)
                    VALUES (?, ?, NULL)
                    """).run(category.keyword, category.parentCategory)
                }
            }

            for keyword in removedKeywords {
                if let clusterId = existingKeywordMap[keyword] {
                    try? db.prepare("UPDATE PhotoFeatures SET cluster_id = -1 WHERE cluster_id = ?").run(clusterId)
                }
                try db.prepare("DELETE FROM ClusterSummary WHERE keyword = ?").run(keyword)
            }
        }
    }

    private func loadDictionaryIntoMemory() {
        guard let db = db else { return }
        categoryCache.removeAll()
        parentCategoryCache.removeAll()

        do {
            var groupedCategories: [String: [CachedCategory]] = [:]
            let query = """
            SELECT c.cluster_id, c.keyword, c.parent_category, s.word_embedding
            FROM ClusterSummary c
            JOIN SemanticDictionary s ON c.keyword = s.keyword
            """
            for row in try db.prepare(query).run() {
                let id = Int(row[0] as? Int64 ?? 1)
                let keyword = row[1] as? String ?? ""
                let parentCategory = row[2] as? String ?? "Uncategorized"
                if let blob = row[3] as? Blob {
                    let wordEmbedding = Data(blob.bytes).toArray(type: Float.self)
                    let cachedCategory = CachedCategory(
                        clusterId: id,
                        keyword: keyword,
                        parentCategory: parentCategory,
                        embedding: wordEmbedding
                    )
                    categoryCache.append(cachedCategory)
                    groupedCategories[parentCategory, default: []].append(cachedCategory)
                }
            }

            parentCategoryCache = groupedCategories.compactMap { parentCategory, children in
                guard let parentEmbedding = averageEmbedding(for: children.map(\.embedding)) else { return nil }
                return CachedParentCategory(
                    name: parentCategory,
                    embedding: parentEmbedding,
                    children: children
                )
            }
            .sorted { $0.name < $1.name }

            print("✅ 成功將 \(categoryCache.count) 筆分類向量載入快取，建立 \(parentCategoryCache.count) 個大分類快取！")
        } catch { print("載入快取失敗: \(error)") }
    }

    func prepareClassificationIfNeeded() {
        classificationPreparationQueue.sync {
            guard !hasPreparedClassification else { return }
            generateMissingSemanticEmbeddingsIfNeeded()
            loadDictionaryIntoMemory()
            hasPreparedClassification = true
        }
    }

    private func generateMissingSemanticEmbeddingsIfNeeded() {
        guard let db = db else { return }

        var missingKeywords: [String] = []
        do {
            let query = """
            SELECT c.keyword
            FROM ClusterSummary c
            LEFT JOIN SemanticDictionary s ON c.keyword = s.keyword
            WHERE s.keyword IS NULL OR s.word_embedding IS NULL
            ORDER BY c.cluster_id ASC
            """
            for row in try db.prepare(query).run() {
                if let keyword = row[0] as? String, !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    missingKeywords.append(keyword)
                }
            }
        } catch {
            print("讀取缺失分類向量失敗: \(error)")
            return
        }

        guard !missingKeywords.isEmpty else { return }
        guard let textModel else {
            print("Text model unavailable, skipping semantic dictionary generation.")
            return
        }

        let tokenizer = CLIPTokenizer()
        var generatedCount = 0

        writeQueue.sync {
            do {
                for keyword in missingKeywords {
                    guard let embedding = self.textEmbedding(for: keyword, tokenizer: tokenizer, model: textModel) else {
                        continue
                    }

                    let embeddingData = Data(buffer: UnsafeBufferPointer(start: embedding, count: embedding.count))
                    try db.prepare("""
                    INSERT OR REPLACE INTO SemanticDictionary (keyword, word_embedding)
                    VALUES (?, ?)
                    """).run(keyword, Blob(bytes: [UInt8](embeddingData)))
                    generatedCount += 1
                }
            } catch {
                print("寫入分類向量失敗: \(error)")
            }
        }

        print("🧠 補齊 \(generatedCount) 筆缺失的分類文字向量。")
    }

    private func textEmbedding(
        for keyword: String,
        tokenizer: CLIPTokenizer,
        model: mobileclip_s2_text
    ) -> [Float]? {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyword.isEmpty else { return nil }

        do {
            let prompt = "a photo of \(trimmedKeyword)"
            let tokenArray = tokenizer.encode_full(text: prompt)
            let tokenMultiArray = try MLMultiArray(shape: [1, 77], dataType: .int32)

            for (index, tokenID) in tokenArray.enumerated() {
                tokenMultiArray[index] = NSNumber(value: tokenID)
            }

            let input = mobileclip_s2_textInput(text: tokenMultiArray)
            let prediction = try model.prediction(input: input)
            return prediction.final_emb_1.toFloatArray().normalized()
        } catch {
            print("文字模型推論失敗 (\(keyword)): \(error)")
            return nil
        }
    }

    private func averageEmbedding(for embeddings: [[Float]]) -> [Float]? {
        guard let firstEmbedding = embeddings.first else { return nil }

        var sum = [Float](repeating: 0, count: firstEmbedding.count)
        for embedding in embeddings where embedding.count == firstEmbedding.count {
            for index in embedding.indices {
                sum[index] += embedding[index]
            }
        }

        var divisor = Float(embeddings.count)
        var averaged = [Float](repeating: 0, count: firstEmbedding.count)
        vDSP_vsdiv(sum, 1, &divisor, &averaged, 1, vDSP_Length(sum.count))
        return averaged.normalized()
    }

    // MARK: - 照片分類查詢
    func fetchGroupedCategories() -> [(main: String, subs: [String])] {
        guard let db = db else { return [] }
        var groupedDict: [String: [String]] = [:]
        var pinnedSet: Set<String> = []
        
        do {
            // 先讀取已釘選的分類
            for row in try db.prepare("SELECT keyword FROM PinnedCategories").run() {
                if let k = row[0] as? String { pinnedSet.insert(k) }
            }
            
            let query = "SELECT parent_category, keyword FROM ClusterSummary"
            let statement = try db.prepare(query)
            for row in try statement.run() {
                if let parent = row[0] as? String, let keyword = row[1] as? String {
                    groupedDict[parent, default: []].append(keyword)
                }
            }
        } catch { print("讀取階層分類失敗: \(error)") }
        
        // 排序邏輯：釘選的子相簿優先，再依字母排序
        return groupedDict.map { (main: $0.key, subs: $0.value) }
            .sorted { $0.main < $1.main }
            .map { group in
                let sortedSubs = group.subs.sorted { a, b in
                    let pA = pinnedSet.contains(a) ? 0 : 1
                    let pB = pinnedSet.contains(b) ? 0 : 1
                    if pA != pB { return pA < pB }
                    return a < b
                }
                return (main: group.main, subs: sortedSubs)
            }
    }

    func fetchPhotos(for keyword: String) -> [String] {
        guard let db = db else { return [] }
        var assetIds: [String] = []
        do {
            let query = """
            SELECT p.asset_id 
            FROM PhotoFeatures p
            JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            WHERE c.keyword = ?
            ORDER BY p.rowid ASC
            """
            for row in try db.prepare(query).run(keyword) {
                if let assetId = row[0] as? String { assetIds.append(assetId) }
            }
        } catch { print("查詢照片失敗: \(error)") }
        return sanitizeAssetIds(assetIds)
    }

    func fetchPhotosWithFavorite(for keyword: String) -> [(id: String, isFavorite: Bool)] {
        guard let db = db else { return [] }
        var results: [(String, Bool)] = []
        do {
            let query = """
            SELECT p.asset_id, p.is_favorite 
            FROM PhotoFeatures p
            JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            WHERE c.keyword = ?
            ORDER BY p.rowid ASC
            """
            for row in try db.prepare(query).run(keyword) {
                if let assetId = row[0] as? String {
                    let isFavInt = row[1] as? Int64 ?? 0
                    results.append((id: assetId, isFavorite: isFavInt == 1))
                }
            }
        } catch { print("讀取最愛狀態失敗: \(error)") }
        let validIds = Set(sanitizeAssetIds(results.map(\.0)))
        return results.filter { validIds.contains($0.0) }
    }

    // MARK: - 照片同步與 AI 自動分類邏輯
    func insertPhotoEmbedding(assetId: String, metadata: String, embeddingData: Data) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                let insertQuery = """
                INSERT INTO PhotoFeatures (asset_id, metadata, image_embedding, cluster_id, is_favorite)
                VALUES (?, ?, ?, NULL, 0)
                ON CONFLICT(asset_id) DO UPDATE SET
                    metadata = excluded.metadata,
                    image_embedding = excluded.image_embedding,
                    cluster_id = NULL
                """
                let statement = try db.prepare(insertQuery)
                try statement.run(assetId, metadata, Blob(bytes: [UInt8](embeddingData)))
            } catch { print("寫入照片失敗: \(error)") }
        }
    }

    func classifyPendingPhotos(limit: Int? = nil) -> Int {
        prepareClassificationIfNeeded()

        let pendingPhotos = fetchPendingClassificationEmbeddings(limit: limit)
        guard !pendingPhotos.isEmpty else { return 0 }

        var classifiedCount = 0
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                let updateStatement = try db.prepare("""
                UPDATE PhotoFeatures
                SET cluster_id = ?
                WHERE asset_id = ?
                """)

                for photo in pendingPhotos {
                    let photoEmbedding = photo.embeddingData.toArray(type: Float.self)
                    let targetClusterId = findBestMatchClusterId(for: photoEmbedding, threshold: classificationThreshold) ?? -1
                    try updateStatement.run(targetClusterId, photo.assetId)
                    classifiedCount += 1
                }
            } catch {
                print("批次分類照片失敗: \(error)")
            }
        }

        if classifiedCount > 0 {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil)
            }
        }
        return classifiedCount
    }

    private func fetchPendingClassificationEmbeddings(limit: Int?) -> [(assetId: String, embeddingData: Data)] {
        guard let db = db else { return [] }

        var results: [(assetId: String, embeddingData: Data)] = []
        do {
            var query = """
            SELECT asset_id, image_embedding
            FROM PhotoFeatures
            WHERE cluster_id IS NULL AND image_embedding IS NOT NULL
            ORDER BY rowid ASC
            """

            if let limit, limit > 0 {
                query += "\nLIMIT \(limit)"
            }

            for row in try db.prepare(query).run() {
                guard let assetId = row[0] as? String, let blob = row[1] as? Blob else { continue }
                results.append((assetId: assetId, embeddingData: Data(blob.bytes)))
            }
        } catch {
            print("讀取待分類照片失敗: \(error)")
        }
        return results
    }

    private func findBestMatchClusterId(for photoEmbedding: [Float], threshold: Float) -> Int? {
        if categoryCache.isEmpty {
            return nil
        }

        let candidateParents = bestParentCategories(for: photoEmbedding, limit: 1)
        let candidateCategories = candidateParents.isEmpty
            ? categoryCache
            : candidateParents.flatMap(\.children)

        var bestId: Int? = nil
        var maxSim: Float = -1.0
        
        for category in candidateCategories {
            let dotProduct = cosineSimilarity(photoEmbedding, category.embedding)
            if dotProduct > maxSim {
                maxSim = dotProduct
                bestId = category.clusterId
            }
        }
        return maxSim >= threshold ? bestId : nil
    }

    private func bestParentCategories(for photoEmbedding: [Float], limit: Int) -> [CachedParentCategory] {
        guard !parentCategoryCache.isEmpty else { return [] }

        return parentCategoryCache
            .map { parentCategory in
                (parentCategory: parentCategory, score: cosineSimilarity(photoEmbedding, parentCategory.embedding))
            }
            .sorted { $0.score > $1.score }
            .prefix(max(1, limit))
            .map(\.parentCategory)
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dotProduct: Float = 0.0
        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        return dotProduct
    }

    func fetchAllScannedAssetIds() -> Set<String> {
        guard let db = db else { return [] }
        var ids = Set<String>()
        do {
            for row in try db.prepare("SELECT asset_id FROM PhotoFeatures").run() {
                if let id = row[0] as? String { ids.insert(id) }
            }
        } catch {}
        return ids
    }

    func fetchAllCategories() -> [String] {
        guard let db = db else { return [] }
        var list: [String] = []
        do {
            for row in try db.prepare("SELECT keyword FROM ClusterSummary").run() {
                if let k = row[0] as? String { list.append(k) }
            }
        } catch {}
        return list
    }

    func fetchPhotosWithDetails(for keyword: String) -> [PhotoListItem] {
        guard let db = db else { return [] }
        var results: [PhotoListItem] = []
        do {
            let query = """
            SELECT p.asset_id, p.is_favorite, c.keyword, p.metadata
            FROM PhotoFeatures p
            JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            WHERE c.keyword = ?
            ORDER BY p.rowid ASC
            """
            for row in try db.prepare(query).run(keyword) {
                guard let assetId = row[0] as? String else { continue }
                let isFav = (row[1] as? Int64 ?? 0) == 1
                let tag   = (row[2] as? String) ?? ""
                var date  = ""
                if let meta = row[3] as? String,
                   let data = meta.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let d = dict["date"] as? String {
                    date = d
                }
                results.append(PhotoListItem(id: assetId, isFavorite: isFav, tag: tag, date: date))
            }
        } catch { print("fetchPhotosWithDetails failed: \(error)") }
        return sanitizePhotoListItems(results)
    }

    func countAllPhotos() -> Int {
        guard let db = db else { return 0 }
        if let row = try? db.prepare("SELECT COUNT(*) FROM PhotoFeatures").run().first(where: { _ in true }),
           let n = row[0] as? Int64 { return Int(n) }
        return 0
    }

    // MARK: - 自定義相簿建立與讀取
    private func createCustomAlbumTablesIfNeeded() {
        guard let db = db else { return }
        do {
            try db.execute("""
            CREATE TABLE IF NOT EXISTS UserAlbums (
                album_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """)

            try db.execute("""
            CREATE TABLE IF NOT EXISTS UserAlbumPhotos (
                album_id TEXT NOT NULL,
                asset_id TEXT NOT NULL,
                position INTEGER DEFAULT 0,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (album_id, asset_id)
            )
            """)
            
            try db.execute("CREATE TABLE IF NOT EXISTS PinnedCategories (keyword TEXT PRIMARY KEY)")
            try? db.execute("ALTER TABLE UserAlbums ADD COLUMN is_pinned INTEGER DEFAULT 0")
        } catch {
            print("建立自定義相簿資料表失敗: \(error)")
        }
    }

    func fetchCustomAlbums() -> [CustomAlbumSummary] {
        guard let db = db else { return [] }
        var albums: [CustomAlbumSummary] = []

        do {
            let query = """
            SELECT
                a.album_id,
                a.title,
                a.is_pinned
            FROM UserAlbums a
            GROUP BY a.album_id, a.title, a.created_at, a.is_pinned
            ORDER BY a.is_pinned DESC, a.created_at ASC
            """

            for row in try db.prepare(query).run() {
                let albumId = row[0] as? String ?? ""
                let title = row[1] as? String ?? ""
                let assetIds = fetchCustomAlbumPhotoAssetIds(albumId: albumId)
                let photoCount = assetIds.count
                let coverAssetId = assetIds.first

                albums.append(CustomAlbumSummary(
                    id: albumId,
                    title: title,
                    coverAssetId: coverAssetId,
                    photoCount: photoCount
                ))
            }
        } catch {
            print("讀取自定義相簿失敗: \(error)")
        }

        return albums
    }

    private func fetchCustomAlbumCoverAssetId(albumId: String, position: Int) -> String? {
        guard let db = db else { return nil }
        do {
            let query = """
            SELECT asset_id
            FROM UserAlbumPhotos
            WHERE album_id = ? AND position = ?
            LIMIT 1
            """
            if let row = try db.prepare(query).run(albumId, position).first(where: { _ in true }) {
                return row[0] as? String
            }
        } catch {
            print("讀取自定義相簿封面失敗: \(error)")
        }
        return nil
    }

    func customAlbumExists(named title: String) -> Bool {
        guard let db = db else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        do {
            let query = """
            SELECT 1
            FROM UserAlbums
            WHERE lower(title) = lower(?)
            LIMIT 1
            """
            return try db.prepare(query).run(trimmed).first(where: { _ in true }) != nil
        } catch {
            print("檢查自定義相簿名稱失敗: \(error)")
            return false
        }
    }

    @discardableResult
    func createCustomAlbum(title: String, assetIds: [String]) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var createdAlbumId: String?
        writeQueue.sync {
            guard let db = self.db else { return }
            let albumId = UUID().uuidString

            do {
                try db.prepare("INSERT INTO UserAlbums (album_id, title) VALUES (?, ?)").run(albumId, trimmed)
                for (index, assetId) in assetIds.enumerated() {
                    try db.prepare("""
                    INSERT OR IGNORE INTO UserAlbumPhotos (album_id, asset_id, position)
                    VALUES (?, ?, ?)
                    """).run(albumId, assetId, index)
                }
                createdAlbumId = albumId
            } catch {
                print("建立自定義相簿失敗: \(error)")
            }
        }

        if createdAlbumId != nil {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil)
            }
        }
        return createdAlbumId
    }

    func fetchCustomAlbumPhotoAssetIds(albumId: String) -> [String] {
        guard let db = db else { return [] }
        var assetIds: [String] = []
        do {
            let query = """
            SELECT asset_id
            FROM UserAlbumPhotos
            WHERE album_id = ?
            ORDER BY position ASC, created_at ASC
            """
            for row in try db.prepare(query).run(albumId) {
                if let assetId = row[0] as? String {
                    assetIds.append(assetId)
                }
            }
        } catch {
            print("讀取自定義相簿照片失敗: \(error)")
        }
        return sanitizeAssetIds(assetIds)
    }

    func fetchCustomAlbumPhotosWithDetails(albumId: String) -> [PhotoListItem] {
        guard let db = db else { return [] }
        var results: [PhotoListItem] = []

        do {
            let query = """
            SELECT p.asset_id, p.is_favorite, COALESCE(c.keyword, ''), p.metadata
            FROM UserAlbumPhotos ap
            JOIN PhotoFeatures p ON ap.asset_id = p.asset_id
            LEFT JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            WHERE ap.album_id = ?
            ORDER BY ap.position ASC, ap.created_at ASC
            """
            for row in try db.prepare(query).run(albumId) {
                guard let assetId = row[0] as? String else { continue }
                let isFav = (row[1] as? Int64 ?? 0) == 1
                let tag = row[2] as? String ?? ""
                var date = ""

                if let meta = row[3] as? String,
                   let data = meta.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let d = dict["date"] as? String {
                    date = d
                }

                results.append(PhotoListItem(id: assetId, isFavorite: isFav, tag: tag, date: date))
            }
        } catch {
            print("讀取自定義相簿詳情失敗: \(error)")
        }

        return sanitizePhotoListItems(results)
    }

    func fetchPhotosWithDetails(forAssetIds assetIds: [String]) -> [PhotoListItem] {
        let validAssetIds = sanitizeAssetIds(assetIds)
        guard !validAssetIds.isEmpty, let db = db else { return [] }

        let validIdSet = Set(validAssetIds)
        var itemsById: [String: PhotoListItem] = [:]
        do {
            let query = """
            SELECT p.asset_id, p.is_favorite, COALESCE(c.keyword, ''), p.metadata
            FROM PhotoFeatures p
            LEFT JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            """
            for row in try db.prepare(query).run() {
                guard let assetId = row[0] as? String else { continue }
                guard validIdSet.contains(assetId) else { continue }
                let isFav = (row[1] as? Int64 ?? 0) == 1
                let tag = row[2] as? String ?? ""
                var date = ""

                if let meta = row[3] as? String,
                   let data = meta.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let d = dict["date"] as? String {
                    date = d
                }

                itemsById[assetId] = PhotoListItem(id: assetId, isFavorite: isFav, tag: tag, date: date)
            }
        } catch {
            print("依 asset ids 讀取照片詳情失敗: \(error)")
        }

        let orderedItems = validAssetIds.compactMap { itemsById[$0] }
        return sanitizePhotoListItems(orderedItems)
    }

    func addPhotos(_ assetIds: [String], toCustomAlbum albumId: String) {
        let dedupedAssetIds = assetIds.reduce(into: [String]()) { partialResult, assetId in
            if !partialResult.contains(assetId) {
                partialResult.append(assetId)
            }
        }

        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                let maxPositionQuery = "SELECT COALESCE(MAX(position), -1) FROM UserAlbumPhotos WHERE album_id = ?"
                let currentMaxPosition = Int((try db.prepare(maxPositionQuery).run(albumId).first(where: { _ in true })?[0] as? Int64) ?? -1)

                for (offset, assetId) in dedupedAssetIds.enumerated() {
                    try db.prepare("""
                    INSERT OR IGNORE INTO UserAlbumPhotos (album_id, asset_id, position)
                    VALUES (?, ?, ?)
                    """).run(albumId, assetId, currentMaxPosition + offset + 1)
                }
            } catch {
                print("新增自定義相簿照片失敗: \(error)")
            }
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil)
        }
    }

    func removePhotoFromCustomAlbum(assetId: String, albumId: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                try db.prepare("""
                DELETE FROM UserAlbumPhotos
                WHERE album_id = ? AND asset_id = ?
                """).run(albumId, assetId)
            } catch {
                print("移除自定義相簿照片失敗: \(error)")
            }
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil)
        }
    }

    // MARK: - 相簿管理 (刪除與釘選)
    func deleteCustomAlbum(albumId: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                try db.prepare("DELETE FROM UserAlbumPhotos WHERE album_id = ?").run(albumId)
                try db.prepare("DELETE FROM UserAlbums WHERE album_id = ?").run(albumId)
                DispatchQueue.main.async { NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil) }
            } catch { print("刪除相簿失敗: \(error)") }
        }
    }

    func togglePinCustomAlbum(albumId: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                try db.prepare("UPDATE UserAlbums SET is_pinned = CASE WHEN is_pinned = 1 THEN 0 ELSE 1 END WHERE album_id = ?").run(albumId)
                DispatchQueue.main.async { NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil) }
            } catch { print("釘選自定義相簿失敗: \(error)") }
        }
    }

    func togglePinCategory(keyword: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                let count = try db.scalar("SELECT COUNT(*) FROM PinnedCategories WHERE keyword = ?", keyword) as? Int64 ?? 0
                if count > 0 {
                    try db.prepare("DELETE FROM PinnedCategories WHERE keyword = ?").run(keyword)
                } else {
                    try db.prepare("INSERT INTO PinnedCategories (keyword) VALUES (?)").run(keyword)
                }
                DispatchQueue.main.async { NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil) }
            } catch { print("釘選分類相簿失敗: \(error)") }
        }
    }

    // MARK: - 照片操作
    func toggleFavorite(assetId: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                try db.prepare("UPDATE PhotoFeatures SET is_favorite = CASE WHEN is_favorite = 1 THEN 0 ELSE 1 END WHERE asset_id = ?").run(assetId)
                DispatchQueue.main.async { NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil) }
            } catch {}
        }
    }

    func deletePhoto(assetId: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                try db.prepare("DELETE FROM UserAlbumPhotos WHERE asset_id = ?").run(assetId)
                try db.prepare("DELETE FROM PhotoFeatures WHERE asset_id = ?").run(assetId)
                DispatchQueue.main.async { NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil) }
            } catch {}
        }
    }

    func movePhoto(assetId: String, to targetKeyword: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                let getID = "SELECT cluster_id FROM ClusterSummary WHERE keyword = ?"
                if let row = try db.prepare(getID).run(targetKeyword).first(where: { _ in true }) {
                    let tid = row[0] as? Int64 ?? 1
                    try db.prepare("UPDATE PhotoFeatures SET cluster_id = ? WHERE asset_id = ?").run(tid, assetId)
                    DispatchQueue.main.async { NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil) }
                }
            } catch {}
        }
    }

    func fetchMetadataAlbumSections() -> [MetadataAlbumSection] {
            guard let db = db else { return [] }

            var rows: [(assetId: String, metadata: String)] = []
            do {
                let query = "SELECT asset_id, metadata FROM PhotoFeatures"
                for row in try db.prepare(query).run() {
                    if let assetId = row[0] as? String {
                        let metadata = row[1] as? String ?? "{}"
                        rows.append((assetId: assetId, metadata: metadata))
                    }
                }
            } catch {
                print("讀取 metadata 相簿失敗: \(error)")
                return []
            }

            let orderedAssetIds = sanitizeAssetIds(rows.map(\.assetId))
            guard !orderedAssetIds.isEmpty else { return [] }

            let metadataById = Dictionary(uniqueKeysWithValues: rows.map { ($0.assetId, $0.metadata) })
            let assetsById = fetchAssetsMap(for: orderedAssetIds)

            // 🌟 核心：多天連續旅程的時間段模型
            class TripBucket {
                let id = UUID().uuidString
                var region: String
                var startDate: Date
                var endDate: Date
                var primaryAssetIds: [String] = []
                var otherAssetIds: [String] = [] // 專門放這趟旅程的截圖/下載照片
                var allLocations: Set<String> = [] // 🌟 新增：收集這趟旅程去過的所有地點

                init(locationLabel: String, region: String, date: Date) {
                    self.region = region
                    self.startDate = date
                    self.endDate = date
                    addLocation(locationLabel)
                }

                func addLocation(_ label: String) {
                    let parts = label.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    parts.forEach { allLocations.insert($0) }
                }

                var title: String {
                    // 扣除掉大區域(如: 冰島)後的地標
                    let candidates = allLocations.filter { $0 != region }
                    // 🌟 智能挑選：優先挑選「不是純數字」的地標當大標題
                    let textCandidates = candidates.filter { Int($0) == nil }.sorted()
                    return textCandidates.first ?? candidates.sorted().first ?? region
                }

                var subtitle: String {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    let startStr = formatter.string(from: startDate)
                    let endStr = formatter.string(from: endDate)
                    let dateStr = startStr == endStr ? startStr : "\(startStr) ~ \(endStr)"
                    
                    // 扣除大標題和區域後，剩下的次要地點放副標題
                    let others = allLocations.filter { $0 != region && $0 != title }.sorted()
                    let trailingLocation = others.isEmpty ? region : others.joined(separator: ", ") + ", \(region)"
                    
                    return "\(dateStr) • \(trailingLocation)"
                }
            }

            var tripBuckets: [TripBucket] = []
            
            // 將所有照片依時間由舊到新排序，才能正確建立時間軸
            let sortedAssets = orderedAssetIds.compactMap { id -> (id: String, asset: PHAsset, date: Date)? in
                guard let asset = assetsById[id], let date = asset.creationDate else { return nil }
                return (id, asset, date)
            }.sorted { $0.date < $1.date }

            var deferredOtherPhotos: [(id: String, date: Date)] = []

            // 第一階段：用相機拍攝的照片建立旅程時間段 (時間門檻：3天)
            let mergeThreshold: TimeInterval = 3 * 24 * 60 * 60
            
            for item in sortedAssets {
                let metaStr = metadataById[item.id] ?? "{}"
                let dict = (try? metadataDictionary(from: metaStr)) ?? [:]
                let locationLabel = resolvedLocationLabel(asset: item.asset, metadata: dict)
                let sourceInfo = sourceInfo(for: item.asset)

                // 如果是下載、截圖、或沒有地點，丟入待處理名單
                if !sourceInfo.label.isEmpty || locationLabel.isEmpty {
                    deferredOtherPhotos.append((id: item.id, date: item.date))
                    continue
                }

                let parts = locationLabel.components(separatedBy: ",")
                let region = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"

                // 🌟 關鍵修正：不再只看「最後一張」，而是往前找「同地區且在 3 天內」的旅程
                if let existingTrip = tripBuckets.last(where: { $0.region == region && item.date.timeIntervalSince($0.endDate) <= mergeThreshold }) {
                    existingTrip.primaryAssetIds.append(item.id)
                    existingTrip.endDate = item.date
                    existingTrip.addLocation(locationLabel) // 把新照片的地點加入收集庫中
                } else {
                    let newTrip = TripBucket(locationLabel: locationLabel, region: region, date: item.date)
                    newTrip.primaryAssetIds.append(item.id)
                    tripBuckets.append(newTrip)
                }
            }

            // 第二階段：將待確認的下載/截圖照片，精準塞入對應的時間段中
            for other in deferredOtherPhotos {
                // 只要照片時間落在旅程的 [startDate - 1天, endDate + 1天] 範圍內，就認定是該旅程的下載照片
                let matchedTrip = tripBuckets.first { trip in
                    other.date >= trip.startDate.addingTimeInterval(-86400) &&
                    other.date <= trip.endDate.addingTimeInterval(86400)
                }

                if let trip = matchedTrip {
                    trip.otherAssetIds.append(other.id)
                }
            }

            // 轉換為 UI 需要的資料結構
            let journeyAlbums = tripBuckets
                .filter { ($0.primaryAssetIds.count + $0.otherAssetIds.count) >= 2 } // 🌟 總數大於等於 2 張才顯示
                .sorted { $0.startDate > $1.startDate } // 畫面最新旅程排最上面
                .map { bucket in
                    MetadataAlbumSummary(
                        id: bucket.id,
                        title: bucket.title,
                        subtitle: bucket.subtitle,
                        coverAssetId: bucket.primaryAssetIds.first ?? bucket.otherAssetIds.first,
                        photoCount: bucket.primaryAssetIds.count + bucket.otherAssetIds.count,
                        primaryAssetIds: bucket.primaryAssetIds,
                        otherAssetIds: bucket.otherAssetIds
                    )
                }

            // 只需要回傳成功配對的旅程相簿即可，沒有配對到旅程的日常截圖不顯示在這裡
            return [
                journeyAlbums.isEmpty ? nil : MetadataAlbumSection(id: "journeys", title: "Journeys", albums: journeyAlbums)
            ].compactMap { $0 }
        }
    
    // MARK: - AI Agent 筆記功能
    private func createNotesTableIfNeeded() {
        guard let db = db else { return }
        do {
            let query = """
            CREATE TABLE IF NOT EXISTS AgentNotes (
                note_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                content TEXT,
                image_assets TEXT, 
                is_favorite INTEGER DEFAULT 0,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
            try db.execute(query)
            try? db.execute("ALTER TABLE AgentNotes ADD COLUMN image_assets TEXT")
        } catch { print("建立筆記表失敗") }
    }

    func fetchNotes(onlyFavorite: Bool = false) -> [(id: String, title: String, isFavorite: Bool)] {
        guard let db = db else { return [] }
        var results: [(String, String, Bool)] = []
        do {
            var q = "SELECT note_id, title, is_favorite FROM AgentNotes"
            if onlyFavorite { q += " WHERE is_favorite = 1" }
            q += " ORDER BY created_at DESC"
            for row in try db.prepare(q).run() {
                results.append((
                    id: row[0] as? String ?? "",
                    title: row[1] as? String ?? "",
                    isFavorite: (row[2] as? Int64 ?? 0) == 1
                ))
            }
        } catch {}
        return results
    }

    func fetchNoteDetail(noteId: String) -> (content: String, images: [UIImage]) {
        guard let db = db else { return ("", []) }
        do {
            let q = "SELECT content, image_assets FROM AgentNotes WHERE note_id = ?"
            if let row = try db.prepare(q).run(noteId).first(where: { _ in true }) {
                let content = row[0] as? String ?? ""
                let imageAssetsString = row[1] as? String ?? ""
                
                var loadedImages: [UIImage] = []
                if !imageAssetsString.isEmpty {
                    let filenames = imageAssetsString.split(separator: ",").map(String.init)
                    loadedImages = filenames.compactMap { loadImageFromDisk(filename: $0) }
                }
                return (content, loadedImages)
            }
        } catch { print("讀取筆記詳情失敗") }
        return ("", [])
    }

    func insertNote(title: String, content: String, images: [UIImage] = []) {
        let filenames = images.compactMap { saveImageToDisk(image: $0) }
        let assetsString = filenames.joined(separator: ",")
        
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                let q = "INSERT INTO AgentNotes (note_id, title, content, image_assets) VALUES (?, ?, ?, ?)"
                try db.prepare(q).run(UUID().uuidString, title, content, assetsString)
            } catch { print("新增筆記失敗") }
        }
    }

    func toggleNoteFavorite(noteId: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do { try db.prepare("UPDATE AgentNotes SET is_favorite = CASE WHEN is_favorite = 1 THEN 0 ELSE 1 END WHERE note_id = ?").run(noteId) } catch {}
        }
    }

    func deleteNote(noteId: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do { try db.prepare("DELETE FROM AgentNotes WHERE note_id = ?").run(noteId) } catch {}
        }
    }
    
    // MARK: - 本機圖片存取輔助
    private func saveImageToDisk(image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        let filename = UUID().uuidString + ".jpg"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
        do {
            try data.write(to: url)
            return filename
        } catch { return nil }
    }

    private func loadImageFromDisk(filename: String) -> UIImage? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
        if let data = try? Data(contentsOf: url) {
            return UIImage(data: data)
        }
        return nil
    }

    // MARK: - 搜尋與 Metadata 讀取
    func searchPhotos(text: String, textEmbedding: [Float]? = nil) -> [String] {
        guard let db = db else { return [] }
        var scoredResults: [(id: String, score: Float)] = []
        let lowerText = text.lowercased()
        let normalizedDateQuery = normalizedDayKey(from: text)

        do {
            let query = """
            SELECT p.asset_id, p.metadata, p.image_embedding, COALESCE(c.keyword, '')
            FROM PhotoFeatures p
            LEFT JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            """
            for row in try db.prepare(query).run() {
                guard let assetId = row[0] as? String else { continue }
                let metadata = (row[1] as? String) ?? ""
                let tag      = (row[3] as? String) ?? ""
                var totalScore: Float = 0.0

                if !lowerText.isEmpty {
                    if tag.lowercased() == lowerText {
                        totalScore += 1.5
                    } else if tag.lowercased().contains(lowerText) {
                        totalScore += 1.0
                    }

                    if let metadataInfo = parsedMetadataInfo(from: metadata) {
                        totalScore += metadataSearchScore(
                            query: lowerText,
                            normalizedDateQuery: normalizedDateQuery,
                            metadata: metadataInfo
                        )
                    }
                }

                if let queryVector = textEmbedding, let blob = row[2] as? Blob {
                    let imageVector = Data(blob.bytes).toArray(type: Float.self)
                    totalScore += cosineSimilarity(queryVector, imageVector)
                }

                if totalScore >= 0.21 {
                    scoredResults.append((id: assetId, score: totalScore))
                }
            }
        } catch { print("搜尋失敗: \(error)") }

        return scoredResults.sorted { $0.score > $1.score }.map { $0.id }
    }

    func updatePhotoMetadata(assetId: String, merge updates: [String: Any]) {
        guard !updates.isEmpty else { return }

        var didUpdate = false
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                let selectQuery = "SELECT metadata FROM PhotoFeatures WHERE asset_id = ?"
                let existingMetadata = try db.prepare(selectQuery).run(assetId).first(where: { _ in true })?[0] as? String ?? "{}"
                var metadataDict = (try? metadataDictionary(from: existingMetadata)) ?? [:]

                for (key, value) in updates {
                    metadataDict[key] = value
                }

                let data = try JSONSerialization.data(withJSONObject: metadataDict, options: [])
                let metadataString = String(data: data, encoding: .utf8) ?? "{}"
                try db.prepare("UPDATE PhotoFeatures SET metadata = ? WHERE asset_id = ?").run(metadataString, assetId)
                didUpdate = true
            } catch {
                print("更新照片 metadata 失敗: \(error)")
            }
        }

        if didUpdate {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil)
            }
        }
    }

    func fetchAssetIdsNeedingLocationMetadata(limit: Int = 50) -> [String] {
        guard let db = db else { return [] }

        var assetIds: [String] = []
        do {
            let query = """
            SELECT asset_id
            FROM PhotoFeatures
            WHERE metadata LIKE '%"latitude"%'
              AND metadata NOT LIKE '%"locationText"%'
            ORDER BY rowid ASC
            LIMIT ?
            """
            for row in try db.prepare(query).run(limit) {
                if let assetId = row[0] as? String {
                    assetIds.append(assetId)
                }
            }
        } catch {
            print("讀取待補地點 metadata 照片失敗: \(error)")
        }
        return assetIds
    }

    private func metadataDictionary(from metadata: String) throws -> [String: Any] {
        guard let data = metadata.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return dict
    }

    private func sanitizePhotoListItems(_ items: [PhotoListItem]) -> [PhotoListItem] {
        let validIds = Set(sanitizeAssetIds(items.map(\.id)))
        return items.filter { validIds.contains($0.id) }
    }

    private func sanitizeAssetIds(_ assetIds: [String]) -> [String] {
        guard !assetIds.isEmpty else { return [] }
        let (validIds, missingIds) = splitExistingAssetIds(assetIds)
        if !missingIds.isEmpty {
            removeMissingAssetsFromDatabase(assetIds: missingIds)
        }
        return validIds
    }

    private func splitExistingAssetIds(_ assetIds: [String]) -> (validIds: [String], missingIds: [String]) {
        let uniqueAssetIds = Array(NSOrderedSet(array: assetIds)).compactMap { $0 as? String }
        guard !uniqueAssetIds.isEmpty else { return ([], []) }

        var existingIds = Set<String>()
        for chunk in uniqueAssetIds.chunked(into: 200) {
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: nil)
            fetchResult.enumerateObjects { asset, _, _ in
                existingIds.insert(asset.localIdentifier)
            }
        }

        let validIds = assetIds.filter { existingIds.contains($0) }
        let missingIds = uniqueAssetIds.filter { !existingIds.contains($0) }
        return (validIds, missingIds)
    }

    private func removeMissingAssetsFromDatabase(assetIds: [String]) {
        guard !assetIds.isEmpty else { return }

        var didUpdate = false
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                for assetId in assetIds {
                    try db.prepare("DELETE FROM UserAlbumPhotos WHERE asset_id = ?").run(assetId)
                    try db.prepare("DELETE FROM PhotoFeatures WHERE asset_id = ?").run(assetId)
                    didUpdate = true
                }
            } catch {
                print("清理失效照片失敗: \(error)")
            }
        }

        if didUpdate {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil)
            }
        }
    }

    private func fetchAssetsMap(for assetIds: [String]) -> [String: PHAsset] {
        guard !assetIds.isEmpty else { return [:] }
        var assetsById: [String: PHAsset] = [:]
        for chunk in assetIds.chunked(into: 200) {
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: nil)
            fetchResult.enumerateObjects { asset, _, _ in
                assetsById[asset.localIdentifier] = asset
            }
        }
        return assetsById
    }

    private func resolvedDayKey(asset: PHAsset, metadata: [String: Any]) -> String {
        if let dayKey = metadata["dayKey"] as? String, !dayKey.isEmpty {
            return dayKey
        }
        if let date = asset.creationDate {
            return metadataDayFormatter.string(from: date)
        }
        return ""
    }

    private func resolvedLocationLabel(asset: PHAsset, metadata: [String: Any]) -> String {
        if let locationText = metadata["locationText"] as? String,
           !locationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return locationText
        }
        if let coordinateText = metadata["coordinateText"] as? String,
           !coordinateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return coordinateText
        }
        if let location = asset.location {
            return String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude)
        }
        return ""
    }

    private func journeyTitle(from locationLabel: String, fallbackDayKey: String) -> String {
        let parts = locationLabel
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let first = parts.first, !first.isEmpty {
            return first
        }
        return fallbackDayKey
    }

    private func journeySubtitle(dayKey: String, locationLabel: String) -> String {
        let title = journeyTitle(from: locationLabel, fallbackDayKey: dayKey)
        let trailingLocation = locationLabel
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .dropFirst()
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        let parts = [dayKey, trailingLocation]
            .filter { !$0.isEmpty && $0.lowercased() != title.lowercased() }
        return parts.joined(separator: " • ")
    }

    private func sourceInfo(for asset: PHAsset) -> (label: String, detail: String) {
        let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? ""
        let normalizedFilename = filename.lowercased()

        let appHints: [(token: String, label: String)] = [
            ("whatsapp", "WhatsApp"),
            ("instagram", "Instagram"),
            ("telegram", "Telegram"),
            ("line", "LINE"),
            ("messenger", "Messenger"),
            ("facebook", "Facebook"),
            ("discord", "Discord"),
            ("slack", "Slack"),
            ("xiaohongshu", "Xiaohongshu"),
            ("rednote", "Rednote"),
            ("tiktok", "TikTok"),
            ("douyin", "Douyin"),
            ("wechat", "WeChat")
        ]

        if let appHint = appHints.first(where: { normalizedFilename.contains($0.token) }) {
            return (appHint.label, filename)
        }

        if asset.sourceType.contains(.typeCloudShared) {
            return ("Shared Album", filename)
        }

        if asset.sourceType.contains(.typeiTunesSynced) {
            return ("Synced Import", filename)
        }

        if !filename.isEmpty && !isGenericCameraFilename(filename) {
            return ("Downloaded / Imported", filename)
        }

        return ("", filename)
    }

    private func isGenericCameraFilename(_ filename: String) -> Bool {
        let uppercased = filename.uppercased()
        let commonPrefixes = ["IMG_", "DSC_", "PXL_", "MVIMG_", "VID_", "PHOTO_", "IMAGE_"]
        return commonPrefixes.contains { uppercased.hasPrefix($0) }
    }

    private func parsedMetadataInfo(from metadata: String) -> (date: String, dayKey: String, locationText: String, coordinateText: String)? {
        guard let dict = try? metadataDictionary(from: metadata) else { return nil }
        let date = (dict["date"] as? String ?? "").lowercased()
        let dayKey = (dict["dayKey"] as? String ?? "").lowercased()
        let locationText = (dict["locationText"] as? String ?? "").lowercased()
        let coordinateText = (dict["coordinateText"] as? String ?? "").lowercased()
        return (date: date, dayKey: dayKey, locationText: locationText, coordinateText: coordinateText)
    }

    private func metadataSearchScore(
        query: String,
        normalizedDateQuery: String?,
        metadata: (date: String, dayKey: String, locationText: String, coordinateText: String)
    ) -> Float {
        var score: Float = 0

        if let normalizedDateQuery, !metadata.dayKey.isEmpty {
            if metadata.dayKey == normalizedDateQuery {
                score += 2.4
            } else if metadata.dayKey.contains(normalizedDateQuery) {
                score += 1.2
            }
        }

        if !metadata.locationText.isEmpty {
            if metadata.locationText == query {
                score += 2.0
            } else if metadata.locationText.contains(query) {
                score += 1.5
            }
        }

        if !metadata.coordinateText.isEmpty, metadata.coordinateText.contains(query) {
            score += 1.0
        }

        if !metadata.date.isEmpty, metadata.date.contains(query) {
            score += 0.8
        }

        return score
    }

    private func normalizedDayKey(from query: String) -> String? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }

        for formatter in queryDateFormatters {
            if let date = formatter.date(from: trimmedQuery) {
                let outputFormatter = DateFormatter()
                outputFormatter.locale = Locale(identifier: "en_US_POSIX")
                outputFormatter.timeZone = .current
                outputFormatter.dateFormat = "yyyy-MM-dd"
                return outputFormatter.string(from: date).lowercased()
            }
        }

        let regexPatterns = [
            #"^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$"#,
            #"^(\d{4})年(\d{1,2})月(\d{1,2})日$"#
        ]

        for pattern in regexPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: trimmedQuery, range: NSRange(trimmedQuery.startIndex..., in: trimmedQuery)),
               match.numberOfRanges == 4,
               let yearRange = Range(match.range(at: 1), in: trimmedQuery),
               let monthRange = Range(match.range(at: 2), in: trimmedQuery),
               let dayRange = Range(match.range(at: 3), in: trimmedQuery) {
                let year = String(trimmedQuery[yearRange])
                let month = String(trimmedQuery[monthRange]).leftPadding(toLength: 2, withPad: "0")
                let day = String(trimmedQuery[dayRange]).leftPadding(toLength: 2, withPad: "0")
                return "\(year)-\(month)-\(day)".lowercased()
            }
        }

        return nil
    }

    func fetchPhotoDetail(assetId: String) -> (metadata: String, tag: String)? {
        guard let db = db else { return nil }
        do {
            let query = """
            SELECT p.metadata, c.keyword
            FROM PhotoFeatures p
            JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            WHERE p.asset_id = ?
            """
            if let row = try db.prepare(query).run(assetId).first(where: { _ in true }) {
                return (row[0] as? String ?? "{}", row[1] as? String ?? "Unknown")
            }
        } catch {}
        return nil
    }
    
    // MARK: - 抓取全部照片 (UI 顯示用)
    func fetchAllPhotosWithDetails() -> [PhotoListItem] {
        guard let db = db else { return [] }
        var results: [PhotoListItem] = []
        
        do {
            let query = """
            SELECT p.asset_id, p.is_favorite, COALESCE(c.keyword, ''), p.metadata
            FROM PhotoFeatures p
            LEFT JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            ORDER BY p.rowid DESC
            """
            for row in try db.prepare(query).run() {
                guard let assetId = row[0] as? String else { continue }
                let isFav = (row[1] as? Int64 ?? 0) == 1
                let tag = row[2] as? String ?? ""
                var date = ""
                
                if let meta = row[3] as? String,
                   let data = meta.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let d = dict["date"] as? String {
                    date = d
                }
                results.append(PhotoListItem(id: assetId, isFavorite: isFav, tag: tag, date: date))
            }
        } catch {
            print("讀取全部照片失敗: \(error)")
        }
        
        return sanitizePhotoListItems(results)
    }
}

// MARK: - 輔助擴充 (Extensions)
extension Data {
    func toArray<T>(type: T.Type) -> [T] {
        return self.withUnsafeBytes { pointer in
            Array(UnsafeBufferPointer(start: pointer.baseAddress!.assumingMemoryBound(to: T.self), count: self.count / MemoryLayout<T>.size))
        }
    }
}

extension String {
    fileprivate func leftPadding(toLength: Int, withPad pad: String) -> String {
        guard count < toLength else { return self }
        return String(repeating: pad, count: toLength - count) + self
    }
}

extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
