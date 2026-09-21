import SwiftUI
import CoreML

enum SemanticPhotoSearch {
    // 整個 App 生命週期只初始化一次文字模型，避免重複載入造成搜尋延遲。
    private static let textModel: mobileclip_s2_text? = {
        try? mobileclip_s2_text(configuration: MLModelConfiguration())
    }()

    static func search(query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var textEmbedding: [Float]? = nil
        do {
            let tokenizer = CLIPTokenizer()
            let tokenArray = tokenizer.encode_full(text: trimmed)
            let tokenMultiArray = try MLMultiArray(shape: [1, 77], dataType: .int32)
            for (index, tokenID) in tokenArray.enumerated() {
                tokenMultiArray[index] = NSNumber(value: tokenID)
            }

            if let textModel {
                let input = mobileclip_s2_textInput(text: tokenMultiArray)
                let prediction = try textModel.prediction(input: input)
                textEmbedding = prediction.final_emb_1.toFloatArray().normalized()
            } else {
                print("Text model unavailable")
            }
        } catch {
            print("文字模型推論失敗：\(error)")
        }

        return DatabaseManager.shared.searchPhotos(text: trimmed, textEmbedding: textEmbedding)
    }
}

// MARK: - 全局搜尋狀態管理
// 集中管理 ML 語意搜尋，讓所有頁面共用同一個搜尋列
class GlobalSearchViewModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var searchResults: [String] = []
    @Published var isSearching: Bool = false

    private var searchTask: Task<Void, Never>? = nil

    // 防抖搜尋入口 (500ms 延遲後執行 ML 推論)
    func executeSearch(query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        searchTask = Task {
            await MainActor.run { self.isSearching = true }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }

            // CoreML 推論放背景執行緒，避免 UI 卡頓
            let results = await Task.detached(priority: .userInitiated) {
                return SemanticPhotoSearch.search(query: trimmed)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    func clear() {
        searchTask?.cancel()
        searchText = ""
        searchResults = []
        isSearching = false
    }
}
