import SwiftUI
import PhotosUI
import Photos
import CoreLocation
import UIKit

// MARK: - 輔助結構
struct IdentifiableString: Identifiable {
    let id: String
}

// 1. 定義單筆對話訊息
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isUser: Bool
    var image: UIImage? = nil
    var canSaveNote: Bool = false // 🌟 新增：控制是否顯示「生成筆記」按鈕
}

private enum ChatAuthor {
    case user
    case assistant

    var title: String {
        switch self {
        case .user: return "" // LINE 風格：不顯示自己的名字
        case .assistant: return "Agent"
        }
    }

    // 🌟 修改：黑白灰泡泡顏色
    var bubbleColor: Color {
        switch self {
        case .user: return Color(white: 0.30) // 使用者：淡灰色 (近白)
        case .assistant: return Color(white: 0.20) // Agent：深灰色
        }
    }

    // 🌟 新增：泡泡內文字顏色
    var textColor: Color {
        switch self {
        case .user: return Color.white // 使用者文字：黑色
        case .assistant: return Color.white // Agent 文字：白色
        }
    }
}

// 2. 對話泡泡 UI 元件
struct MessageBubble: View {
    let message: ChatMessage
    var onGenerateNote: (() -> Void)? = nil
    
    var body: some View {
        let author = message.isUser ? ChatAuthor.user : ChatAuthor.assistant
        let maxBubbleWidth = UIScreen.main.bounds.width * 0.75

        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
            
            if !author.title.isEmpty {
                Text(author.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.horizontal, 4)
            }

            if let img = message.image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            if !message.text.isEmpty {
                bubbleContainer(author: author) {
                    // 🌟 修正 1：改用原生 Text，加大字體至 18，並使用 fixedSize 避免截斷
                    Text(createAttributedString(from: message.text))
                        .font(.system(size: 18))
                        .foregroundColor(author.textColor)
                        .textSelection(.enabled) // 允許長按選取
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: maxBubbleWidth, alignment: message.isUser ? .trailing : .leading)
            }
            
            if !message.isUser && message.canSaveNote {
                Button(action: {
                    onGenerateNote?()
                }) {
                    Label("生成筆記", systemImage: "doc.text.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(12)
                }
                .padding(.leading, 4)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }

    private func bubbleContainer<Content: View>(
        author: ChatAuthor,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(author.bubbleColor)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    
    // 輔助方法：處理 Markdown 渲染
    private func createAttributedString(from text: String) -> AttributedString {
        let textToParse = text.replacingOccurrences(of: "\n", with: "  \n")
        if let attr = try? AttributedString(markdown: textToParse, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attr
        }
        return AttributedString(text)
    }
}

// MARK: - 主視圖 AgentView
struct AgentView: View {
    @State private var topTab: Int = 0        // 0: 智慧助手, 1: LIBRARY
    @State private var libraryTab: Int = 0    // 0: All Notes, 1: Favorite
    @State private var notesFilter: String = "" // LIBRARY 本地筆記過濾
    
    @State private var isLoading = false

    // --- 對話輸入狀態 ---
    @State private var promptText: String = ""
    @State private var selectedChatPhotos: [PhotosPickerItem] = []
    @State private var selectedUIImages: [UIImage] = []
    @State private var showSinglePicker = false
    @State private var stagedTask: String? = nil
    @FocusState private var promptFieldFocused: Bool
    @FocusState private var notesFilterFocused: Bool
    @State private var chatHistory: [ChatMessage] = []

    // --- 資料與 UI 狀態 ---
    @State private var availableAlbums: [String] = []
    @State private var notes: [(id: String, title: String, isFavorite: Bool)] = []
    @State private var showShareSheet = false
    @State private var textToShare: String = ""

    @EnvironmentObject var syncVM: PhotoSyncViewModel

    // 依本地過濾文字篩選筆記
    var filteredNotes: [(id: String, title: String, isFavorite: Bool)] {
        let baseNotes = libraryTab == 1 ? notes.filter { $0.isFavorite } : notes
        guard !notesFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return baseNotes
        }
        return baseNotes.filter { $0.title.localizedCaseInsensitiveContains(notesFilter) }
    }

    var body: some View {
        NavigationStack {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                    // Header
                    HStack {
                        Spacer()

                        Text("Agent")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)

                        Spacer()

                        Button(action: { startNewChat() }) {
                            Image(systemName: "trash")
                                .font(.system(size: 20))
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(.top, 10)
                    .padding(.horizontal, 20)

                    // 頂部切換標籤
                    HStack(spacing: 0) {
                        TabButton(title: "智慧助手", isSelected: topTab == 0) {
                            UIApplication.shared.dismissKeyboard()
                            promptFieldFocused = false
                            notesFilterFocused = false
                            topTab = 0
                        }
                        TabButton(title: "LIBRARY", isSelected: topTab == 1) {
                            UIApplication.shared.dismissKeyboard()
                            promptFieldFocused = false
                            notesFilterFocused = false
                            topTab = 1
                        }
                    }
                    .background(Color.white.opacity(0.15))
                    .cornerRadius(20)
                    .padding(.horizontal, 20)

                    // 分頁內容
                    if topTab == 0 {
                        chatView
                    } else {
                        libraryView
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    UIApplication.shared.dismissKeyboard()
                    promptFieldFocused = false
                    notesFilterFocused = false
                }
            )
            .dismissKeyboardOnTap()
        }
        .photosPicker(
            isPresented: $showSinglePicker,
            selection: $selectedChatPhotos,
            maxSelectionCount: 5,
            matching: .images
        )
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [textToShare])
        }
        .onAppear { loadNotes() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NoteFavoriteChanged"))) { _ in
            loadNotes()
        }
        .onChange(of: selectedChatPhotos) { _, newItems in loadSelectedImages(from: newItems) }
    }

    // MARK: - 智慧助手對話區 (對話模式)
    private var chatView: some View {
        VStack {
            // 1. 對話紀錄顯示區
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 15) {
                        ForEach(chatHistory) { msg in
                            // 🌟 傳入點擊事件，發送儲存指令給 Agent
                            MessageBubble(message: msg) {
                                promptText = "請幫我將上述對話整理成筆記"
                                unifiedSubmit()
                            }
                        }
                        // Loading 動畫
                        if isLoading {
                            HStack {
                                ProgressView().tint(.white)
                                Spacer()
                            }.padding()
                        }
                    }
                    .padding()
                    .id("Bottom")
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chatHistory.count) { _ in
                    withAnimation { proxy.scrollTo("Bottom", anchor: .bottom) }
                }
            }

            // 2. 暫存圖片預覽區
            if !selectedUIImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 15) {
                        ForEach(0..<selectedUIImages.count, id: \.self) { index in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: selectedUIImages[index])
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 50, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                Button(action: {
                                    selectedUIImages.remove(at: index)
                                    if index < selectedChatPhotos.count {
                                        selectedChatPhotos.remove(at: index)
                                    }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.white)
                                        .background(Circle().fill(Color.black))
                                        .offset(x: 8, y: -8)
                                }
                            }
                            .padding([.top, .trailing], 8)
                        }
                    }
                    .padding(.horizontal, 25)
                }
                .padding(.bottom, 5)
            }

            // 3. 輸入控制列
            HStack(alignment: .bottom, spacing: 12) {
                Button(action: { showSinglePicker = true }) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                        .padding(.bottom, 10)
                }

                TextField("Ask anything...", text: $promptText, axis: .vertical)
                    .lineLimit(1...5)
                    .foregroundColor(.white)
                    .focused($promptFieldFocused)
                    .submitLabel(.send)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .cornerRadius(15)
                    .onSubmit {
                        unifiedSubmit()
                    }

                Button(action: { unifiedSubmit() }) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 20))
                        .foregroundColor(canSubmit && !isLoading ? .white : .gray)
                        .padding(.bottom, 10)
                }
                .disabled(!canSubmit || isLoading)
            }
            .padding()
            .background(Color(white: 0.15))
            .cornerRadius(30)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    // MARK: - LIBRARY 筆記列表
    private var libraryView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                Button(action: { libraryTab = 0 }) {
                    Text("All Notes")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(libraryTab == 0 ? .white : .gray)
                }
                Button(action: { libraryTab = 1 }) {
                    Text("Favorite")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(libraryTab == 1 ? .white : .gray)
                }
                Spacer()
            }
            .padding(.horizontal, 20)

            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundColor(.white.opacity(0.5))
                    .font(.system(size: 15))
                TextField("Filter notes...", text: $notesFilter)
                    .foregroundColor(.white)
                    .font(.system(size: 15))
                    .focused($notesFilterFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        notesFilterFocused = false
                        UIApplication.shared.dismissKeyboard()
                    }
                if !notesFilter.isEmpty {
                    Button(action: { notesFilter = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.1))
            .cornerRadius(10)
            .padding(.horizontal, 20)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 15) {
                    ForEach(filteredNotes, id: \.id) { note in
                        NavigationLink(
                            destination: NoteDetailView(noteId: note.id, noteTitle: note.title)
                        ) {
                            HStack(spacing: 0) {
                                VStack(alignment: .leading) {
                                    Text(note.title.displayNoteTitle)
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                }
                                .padding(.leading, 20)

                                Spacer()

                                Button(action: {
                                    DatabaseManager.shared.toggleNoteFavorite(noteId: note.id)
                                    loadNotes()
                                }) {
                                    ZStack {
                                        Rectangle().foregroundColor(.clear).frame(width: 37, height: 37)
                                        Image(systemName: note.isFavorite ? "heart.fill" : "heart")
                                            .resizable().aspectRatio(contentMode: .fit)
                                            .frame(width: 24, height: 24)
                                            .foregroundColor(note.isFavorite ? .red : .white)
                                    }
                                }
                                .padding(.trailing, 10)

                                Image(systemName: "chevron.right")
                                    .foregroundColor(.gray)
                                    .padding(.trailing, 20)
                            }
                            .frame(maxWidth: .infinity).frame(height: 110)
                            .background(Color.white.opacity(0.25)).cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(action: {
                                let noteData = DatabaseManager.shared.fetchNoteDetail(noteId: note.id)
                                textToShare = "\(note.title.displayNoteTitle)\n\n\(noteData.content)"
                                showShareSheet = true
                            }) { Label("Share", systemImage: "square.and.arrow.up") }

                            Button(action: {
                                DatabaseManager.shared.toggleNoteFavorite(noteId: note.id)
                                loadNotes()
                            }) {
                                Label(
                                    note.isFavorite ? "Remove Favorite" : "Favorite",
                                    systemImage: note.isFavorite ? "heart.fill" : "heart"
                                )
                            }

                            Button(role: .destructive, action: {
                                DatabaseManager.shared.deleteNote(noteId: note.id)
                                loadNotes()
                            }) { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: - Logic

    private var canSubmit: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedUIImages.isEmpty
            || stagedTask != nil
    }

    private func loadSelectedImages(from items: [PhotosPickerItem]) {
        Task {
            var images: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    images.append(uiImage)
                }
            }
            await MainActor.run { self.selectedUIImages = images }
        }
    }

    private func unifiedSubmit() {
        let userMessage = promptText
        promptFieldFocused = false
        UIApplication.shared.dismissKeyboard()
        let trimmedMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty || !selectedUIImages.isEmpty else { return }
        
        // 1. 將使用者訊息加入泡泡
        chatHistory.append(ChatMessage(text: trimmedMessage, isUser: true, image: selectedUIImages.first))
        
        // 🌟 新增：打包歷史對話紀錄
        var contextString = ""
        if chatHistory.count > 1 {
            contextString = "【系統提示：以下是我們稍早的對話紀錄】\n"
            for msg in chatHistory.dropLast() {
                let role = msg.isUser ? "使用者" : "你(AI)"
                if !msg.text.isEmpty {
                    contextString += "[\(role)]: \(msg.text)\n"
                }
                if msg.image != nil {
                    contextString += "[\(role)]: （已附上一張圖片）\n"
                }
            }
            contextString += "【系統提示：對話紀錄結束，請根據上述脈絡執行以下最新指令】\n\n指令："
        }
        
        
        // 🌟 判定使用者是否點擊了生成筆記按鈕
        let isNoteGeneration = trimmedMessage.contains("整理成筆記")
        var finalMessageToSend = contextString.isEmpty ? trimmedMessage : (contextString + trimmedMessage)
        
        if isNoteGeneration {
            // 隱藏指令：要求整理「完整內容」＋ 強制呼叫存檔工具
            finalMessageToSend += "\n\n【系統強制指令】：請綜合整理我們『以上的完整對話紀錄與照片分析』，並「必須」立即呼叫 `save_note` 存檔工具！這非常重要，請勿只用純文字回覆！"
        } else {
            // 一般對話的排版要求
            finalMessageToSend += "\n\n【重要排版要求】：請在所有標題 (#, ##, ###) 和條列項目 (- ) 前後，務必使用雙換行 \n\n 以確保段落清晰。"
        }
        
        isLoading = true
        let firstImage = selectedUIImages.first
        let attachedImages = chatHistory.compactMap { $0.image }
        
        // 2. 清除輸入列狀態
        promptText = ""
        selectedChatPhotos = []
        selectedUIImages = []
        
        Task {
            do {
                // 🌟 修改：將 finalMessageToSend 傳給後端
                let response = try await APIService.shared.askAgent(message: finalMessageToSend, image: firstImage)
                
                await MainActor.run {
                    var replyText = response.final_answer

                    for file in response.safeFiles {
                        if file.content_type == "application/pdf" {
                            replyText += "\n\n(系統提示：已為您產生 PDF 檔案『\(file.filename.displayNoteTitle)』，已自動存入 Library。)"
                            let pdfContent = "PDF_BASE64::\(file.base64_data)"
                            DatabaseManager.shared.insertNote(title: file.filename.displayNoteTitle, content: pdfContent, images: attachedImages)
                        } else if file.content_type == "text/markdown" || file.content_type == "text/plain" {
                            if let data = Data(base64Encoded: file.base64_data),
                               let noteText = String(data: data, encoding: .utf8) {
                                let formattedNote = formatAgentContent(noteText)
                                replyText += "\n\n(系統提示：已為您產生筆記檔案『\(file.filename.displayNoteTitle)』，已自動存入 Library。)"
                                DatabaseManager.shared.insertNote(title: file.filename.displayNoteTitle, content: formattedNote, images: attachedImages)
                            }
                        }
                    }
                    
                    // 3. 將 AI 回覆加入泡泡
                    // 🌟 修改：如果沒有產生檔案，代表是純文字對話，則允許使用者手動點擊「生成筆記」
                    let hasGeneratedFiles = !response.safeFiles.isEmpty
                    chatHistory.append(ChatMessage(
                        text: replyText,
                        isUser: false,
                        canSaveNote: !hasGeneratedFiles // 避免重複生成
                    ))
                    
                    self.isLoading = false
                    self.loadNotes()
                }
                
            } catch {
                await MainActor.run {
                    chatHistory.append(ChatMessage(text: "連線失敗：請確認伺服器已啟動且網路正常 (\(error.localizedDescription))", isUser: false))
                    self.isLoading = false
                }
            }
        }
    }
    
    private func loadNotes() {
        notes = DatabaseManager.shared.fetchNotes()
        availableAlbums = DatabaseManager.shared.fetchAllCategories()
    }
    
    private func formatAgentContent(_ text: String) -> String {
        // 簡單的清理：移除多餘的 CR，並確保段落之間有足夠的空行
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n") // 把過多空白縮減
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanMarkdownMarkers(_ text: String) -> String {
        text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "##", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func startNewChat() {
        withAnimation {
            chatHistory.removeAll()
        }
        promptText = ""
        selectedUIImages.removeAll()
        selectedChatPhotos.removeAll()
        stagedTask = nil
    }
}

// MARK: - Helper Components

struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isSelected ? Color.white : Color.clear)
                .foregroundColor(isSelected ? .black : .white)
                .cornerRadius(20)
        }
    }
}

struct PlainTextComponent: UIViewRepresentable {
    var text: String
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textColor = .white
        textView.font = .systemFont(ofSize: 16)
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        // 這裡直接賦值，不經過 Markdown 解析器
        uiView.text = text
    }
}

struct ThumbnailLoader: View {
    let assetId: String
    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        }
        .onAppear {
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
            if let asset = fetchResult.firstObject {
                let manager = PHImageManager.default()
                let options = PHImageRequestOptions()
                options.deliveryMode = .fastFormat
                options.isNetworkAccessAllowed = true
                manager.requestImage(
                    for: asset,
                    targetSize: CGSize(width: 200, height: 200),
                    contentMode: .aspectFill,
                    options: options
                ) { img, _ in
                    DispatchQueue.main.async { self.image = img }
                }
            }
        }
    }
}
