import Foundation
import CoreML
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct Config {
    let sqlitePath: String
    let modelPackagePath: String
    let resourcesPath: String
    let promptPrefix: String
    let forceRecompile: Bool
}

enum CLIError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case sqlite(message: String)
    case coreML(String)

    var description: String {
        switch self {
        case .invalidArguments(let message),
             .sqlite(let message),
             .coreML(let message):
            return message
        }
    }
}

func parseArguments() throws -> Config {
    let arguments = Array(CommandLine.arguments.dropFirst())
    var sqlitePath = "MobileCLIPExplore/SQLite/PhotoAI.sqlite"
    var modelPackagePath = "MobileCLIPExplore/Models/mobileclip_s2_text.mlpackage"
    var resourcesPath = "MobileCLIPExplore/Resources"
    var promptPrefix = "a photo of"
    var forceRecompile = false

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--sqlite":
            index += 1
            guard index < arguments.count else {
                throw CLIError.invalidArguments("Missing value for --sqlite")
            }
            sqlitePath = arguments[index]
        case "--model":
            index += 1
            guard index < arguments.count else {
                throw CLIError.invalidArguments("Missing value for --model")
            }
            modelPackagePath = arguments[index]
        case "--resources":
            index += 1
            guard index < arguments.count else {
                throw CLIError.invalidArguments("Missing value for --resources")
            }
            resourcesPath = arguments[index]
        case "--prompt-prefix":
            index += 1
            guard index < arguments.count else {
                throw CLIError.invalidArguments("Missing value for --prompt-prefix")
            }
            promptPrefix = arguments[index]
        case "--force-recompile":
            forceRecompile = true
        case "--help":
            print("""
            Usage:
              xcrun swift ... generate_text_embeddings.swift -- [options]

            Options:
              --sqlite PATH          SQLite file to update
              --model PATH           mobileclip_s2_text.mlpackage path
              --resources PATH       folder containing clip-vocab.json and clip-merges.txt
              --prompt-prefix TEXT   prompt prefix, default: "a photo of"
              --force-recompile      rebuild the cached mlmodelc before running
            """)
            Foundation.exit(0)
        default:
            throw CLIError.invalidArguments("Unknown argument: \(argument)")
        }
        index += 1
    }

    return Config(
        sqlitePath: sqlitePath,
        modelPackagePath: modelPackagePath,
        resourcesPath: resourcesPath,
        promptPrefix: promptPrefix,
        forceRecompile: forceRecompile
    )
}

func normalize(_ values: [Float]) -> [Float] {
    let squaredSum = values.reduce(Float.zero) { $0 + $1 * $1 }
    let length = sqrt(squaredSum)
    guard length > 0 else { return values }
    return values.map { $0 / length }
}

func data(from values: [Float]) -> Data {
    values.withUnsafeBufferPointer { buffer in
        Data(buffer: buffer)
    }
}

func fetchMissingKeywords(database: OpaquePointer?) throws -> [String] {
    let sql = """
    SELECT c.keyword
    FROM ClusterSummary c
    LEFT JOIN SemanticDictionary s ON c.keyword = s.keyword
    WHERE s.keyword IS NULL OR s.word_embedding IS NULL
    ORDER BY c.cluster_id ASC
    """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw CLIError.sqlite(message: String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }

    var keywords: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        if let cString = sqlite3_column_text(statement, 0) {
            keywords.append(String(cString: cString))
        }
    }
    return keywords
}

func writeEmbedding(
    database: OpaquePointer?,
    keyword: String,
    embeddingData: Data
) throws {
    let sql = """
    INSERT OR REPLACE INTO SemanticDictionary (keyword, word_embedding)
    VALUES (?, ?)
    """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw CLIError.sqlite(message: String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_bind_text(statement, 1, keyword, -1, sqliteTransient) == SQLITE_OK else {
        throw CLIError.sqlite(message: String(cString: sqlite3_errmsg(database)))
    }

    let bindResult = embeddingData.withUnsafeBytes { bytes in
        sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(embeddingData.count), sqliteTransient)
    }
    guard bindResult == SQLITE_OK else {
        throw CLIError.sqlite(message: String(cString: sqlite3_errmsg(database)))
    }

    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw CLIError.sqlite(message: String(cString: sqlite3_errmsg(database)))
    }
}

func prepareCompiledModel(packageURL: URL, forceRecompile: Bool) throws -> URL {
    let fileManager = FileManager.default
    let cacheDirectory = packageURL.deletingLastPathComponent().appendingPathComponent(".model-cache", isDirectory: true)
    let compiledModelURL = cacheDirectory.appendingPathComponent("mobileclip_s2_text.mlmodelc", isDirectory: true)

    if forceRecompile, fileManager.fileExists(atPath: compiledModelURL.path) {
        try fileManager.removeItem(at: compiledModelURL)
    }

    if fileManager.fileExists(atPath: compiledModelURL.path) {
        return compiledModelURL
    }

    try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let temporaryCompiledURL = try MLModel.compileModel(at: packageURL)
    if fileManager.fileExists(atPath: compiledModelURL.path) {
        try fileManager.removeItem(at: compiledModelURL)
    }
    try fileManager.copyItem(at: temporaryCompiledURL, to: compiledModelURL)
    return compiledModelURL
}

func embeddingForKeyword(
    keyword: String,
    promptPrefix: String,
    tokenizer: CLIPTokenizer,
    model: MLModel
) throws -> [Float] {
    let prompt = "\(promptPrefix) \(keyword)"
    let tokenArray = tokenizer.encode_full(text: prompt)
    let tokenMultiArray = try MLMultiArray(shape: [1, 77], dataType: .int32)
    for (index, tokenID) in tokenArray.enumerated() {
        tokenMultiArray[index] = NSNumber(value: tokenID)
    }

    let input = try MLDictionaryFeatureProvider(dictionary: [
        "text": MLFeatureValue(multiArray: tokenMultiArray)
    ])
    let output = try model.prediction(from: input)
    guard let embedding = output.featureValue(for: "final_emb_1")?.multiArrayValue else {
        throw CLIError.coreML("Model output final_emb_1 was missing.")
    }

    let count = embedding.count
    let pointer = embedding.dataPointer.bindMemory(to: Float.self, capacity: count)
    let values = Array(UnsafeBufferPointer(start: pointer, count: count))
    return normalize(values)
}

func run() throws {
    let config = try parseArguments()

    let sqliteURL = URL(fileURLWithPath: config.sqlitePath).standardizedFileURL
    let modelPackageURL = URL(fileURLWithPath: config.modelPackagePath).standardizedFileURL
    let resourcesURL = URL(fileURLWithPath: config.resourcesPath).standardizedFileURL

    var database: OpaquePointer?
    guard sqlite3_open(sqliteURL.path, &database) == SQLITE_OK else {
        throw CLIError.sqlite(message: "Unable to open SQLite database at \(sqliteURL.path)")
    }
    defer { sqlite3_close(database) }

    let missingKeywords = try fetchMissingKeywords(database: database)
    if missingKeywords.isEmpty {
        print("No missing text embeddings found.")
        return
    }

    let compiledModelURL = try prepareCompiledModel(packageURL: modelPackageURL, forceRecompile: config.forceRecompile)
    let model = try MLModel(contentsOf: compiledModelURL)
    let tokenizer = CLIPTokenizer(resourceDirectory: resourcesURL)

    guard sqlite3_exec(database, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
        throw CLIError.sqlite(message: String(cString: sqlite3_errmsg(database)))
    }

    do {
        for (index, keyword) in missingKeywords.enumerated() {
            let embedding = try embeddingForKeyword(
                keyword: keyword,
                promptPrefix: config.promptPrefix,
                tokenizer: tokenizer,
                model: model
            )
            try writeEmbedding(database: database, keyword: keyword, embeddingData: data(from: embedding))
            print("[\(index + 1)/\(missingKeywords.count)] \(keyword)")
        }

        guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw CLIError.sqlite(message: String(cString: sqlite3_errmsg(database)))
        }
    } catch {
        sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        throw error
    }

    print("Generated \(missingKeywords.count) text embeddings into \(sqliteURL.path).")
}

@main
struct GenerateTextEmbeddingsCLI {
    static func main() {
        do {
            try run()
        } catch {
            fputs("Error: \(error)\n", stderr)
            Darwin.exit(1)
        }
    }
}
