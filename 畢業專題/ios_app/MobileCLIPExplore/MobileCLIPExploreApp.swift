import SwiftUI
import BackgroundTasks
import UIKit
import GoogleSignIn // 👈 1. 頂部必須引入這個

@main
struct MobileCLIPExploreApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    
    // 1. 在最外層建立 SyncViewModel
    @StateObject private var syncVM = PhotoSyncViewModel()
    
    // 2. 引入語言設定
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .english

    var body: some Scene {
        WindowGroup {
            ContentView()
                // 3. 注入 EnvironmentObject 給所有子視圖使用
                .environmentObject(syncVM)
                // 4. 強制整個 App 根據設定切換語言
                .environment(\.locale, .init(identifier: appLanguage.rawValue))
                
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                
                .onAppear {
                    BackgroundSyncCoordinator.shared.schedule()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        BackgroundSyncCoordinator.shared.schedule()
                    }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundSyncCoordinator.shared.register()
        return true
    }
}

final class BackgroundSyncCoordinator {
    static let shared = BackgroundSyncCoordinator()

    private let taskIdentifier = "com.elaine.MobileCLIPExplore.photosync.processing"
    private let worker = PhotoSyncViewModel()

    private init() {}

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            self.handle(processingTask)
        }
    }

    func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)

        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("背景同步任務已排程")
        } catch {
            print("背景同步排程失敗: \(error)")
        }
    }

    private func handle(_ task: BGProcessingTask) {
        schedule()

        let expirationState = LockedFlag()
        task.expirationHandler = {
            expirationState.value = true
        }

        DispatchQueue.global(qos: .utility).async {
            let summary = self.worker.performBackgroundSync(
                scanLimit: 20,
                classificationLimit: 50,
                shouldContinue: { !expirationState.value }
            )

            let success = !expirationState.value
            print("背景同步完成：新增 embedding \(summary.embeddedCount) 張，分類 \(summary.classifiedCount) 張，success=\(success)")
            task.setTaskCompleted(success: success)
        }
    }
}

final class LockedFlag {
    private let queue = DispatchQueue(label: "com.photoai.background.flag")
    private var storage = false

    var value: Bool {
        get { queue.sync { storage } }
        set { queue.sync { storage = newValue } }
    }
}
