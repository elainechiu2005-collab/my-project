import SwiftUI

struct ContentView: View {
    @AppStorage("isLoggedIn") var isLoggedIn = false
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .english // 🌟 讀取全域語言設定
    
    @StateObject private var syncVM = PhotoSyncViewModel()

    var body: some View {
        Group { // 🌟 用 Group 包覆，方便統一注入環境變數
            if isLoggedIn {
                MainTabView()
                    .environmentObject(syncVM)
            } else {
                LoginView(isLoggedIn: $isLoggedIn)
            }
        }
        .environment(\.locale, .init(identifier: appLanguage.rawValue)) // 🌟 強制全 App 套用當前語言
        .animation(.easeInOut, value: isLoggedIn) // 讓登入/登出有平滑的漸變動畫
    }
}

#Preview {
    ContentView()
}
