import Foundation
import UIKit

struct ChatRequest: Codable {
    let user_message: String
    let image_base64: String?
}

struct FileData: Codable {
    let filename: String
    let content_type: String
    let base64_data: String
}

struct ChatResponse: Codable {
    let final_answer: String
    let files: [FileData]?

    var safeFiles: [FileData] {
        files ?? []
    }
}

class APIService {
    static let shared = APIService()

    var baseURL: String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "AGENT_API_BASE_URL") as? String,
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return configured
        }

        if let envURL = ProcessInfo.processInfo.environment["AGENT_API_BASE_URL"],
           !envURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envURL
        }

        return "http://172.31.100.110:8000/chat"
    }
    
    // 1. 建立一個具有 300 秒（5 分鐘）超時限制的專屬 Session
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3000
        config.timeoutIntervalForResource = 3000
        return URLSession(configuration: config)
    }()
    
    func askAgent(message: String, image: UIImage?) async throws -> ChatResponse {
        guard let url = URL(string: baseURL) else { throw URLError(.badURL) }
        
        // 將圖片壓縮並轉為 Base64
        var base64String: String? = nil
        if let image = image, let imageData = image.jpegData(compressionQuality: 0.3) {
            base64String = imageData.base64EncodedString()
        }
        
        let requestData = ChatRequest(user_message: message, image_base64: base64String)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestData)
        
        // 2. 使用自訂的 session 發送請求
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        return try JSONDecoder().decode(ChatResponse.self, from: data)
    }
}
