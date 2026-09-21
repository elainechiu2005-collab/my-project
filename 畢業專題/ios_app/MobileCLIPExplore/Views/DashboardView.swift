import SwiftUI
import Photos
import UIKit

private enum DashboardGalleryMode: String, CaseIterable, Identifiable {
    case allPhotos = "All Photos"
    case dictionary = "Classification"
    case metadata = "Time & Place"

    var id: String { rawValue }
}

struct DashboardView: View {
    @State private var searchText: String = ""
    @State private var searchResults: [String] = []
    @State private var allPhotoAssetIds: [String] = []
    @State private var groupedCategories: [(main: String, subs: [String])] = []
    @State private var metadataAlbumSections: [MetadataAlbumSection] = []
    @State private var isLoadingAllPhotos = false
    @State private var isLoadingMetadataAlbums = false
    @State private var customAlbums: [CustomAlbumSummary] = []
    @State private var hasAutoScanned = false
    @State private var isSearching: Bool = false
    @State private var hasSearched: Bool = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var allPhotosLoadTask: Task<Void, Never>? = nil
    @State private var metadataLoadTask: Task<Void, Never>? = nil
    @State private var selectedResultAssetId: IdentifiableString? = nil
    @State private var showSyncBanner: Bool = false
    @State private var syncBannerCount: Int = 0
    @State private var showCreateCustomAlbumSheet = false
    @State private var pendingCustomAlbumName = ""
    @State private var isPreparingCustomAlbum = false
    @State private var customAlbumDraft: CustomAlbumDraft?
    @State private var customAlbumErrorMessage = ""
    
    @State private var showDeleteAlbumAlert = false
    @State private var targetAlbumId: String? = nil
    @State private var isCustomAlbumTarget = false
    
    @State private var currentMode: DashboardGalleryMode = .allPhotos
    
    @State private var allPhotos: [PhotoListItem] = []
    let fiveColumnGrid = Array(repeating: GridItem(.flexible(), spacing: 2), count: 5)

    @EnvironmentObject var syncVM: PhotoSyncViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {

                    if showSyncBanner {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Synced \(syncBannerCount) new photos")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.1))
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.white)

                            Spacer()

                            if syncVM.isSyncing {
                                Text("\(syncVM.syncedCount) / \(syncVM.totalCount)")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.gray)
                            }

                            Button(action: {
                                if syncVM.isSyncing {
                                    syncVM.stopSync() // 🌟 點擊暫停/停止
                                } else {
                                    syncVM.startSync() // 🌟 點擊開始
                                }
                            }) {
                                ZStack {
                                    // 中間的圖示：同步中顯示「暫停」，未同步顯示「重整」
                                    Image(systemName: syncVM.isSyncing ? "pause.fill" : "arrow.triangle.2.circlepath")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundColor(.white)
                                    
                                    // 旋轉的進度外圈 (只有在同步時才會顯示並旋轉)
                                    if syncVM.isSyncing {
                                        Circle()
                                            .trim(from: 0, to: 0.75)
                                            .stroke(Color.white, lineWidth: 2.5)
                                            .rotationEffect(Angle(degrees: syncVM.isSyncing ? 360 : 0))
                                            .animation(
                                                Animation.linear(duration: 1).repeatForever(autoreverses: false),
                                                value: syncVM.isSyncing
                                            )
                                    }
                                }
                                .frame(width: 38, height: 38)
                                .background(Color.white.opacity(0.2))
                                .clipShape(Circle())
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 10)

                        HStack(alignment: .center, spacing: 12) {
                            Text(searchText.isEmpty ? "ALBUMS" : "SEARCH RESULTS")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)

                            Spacer()

                            if searchText.isEmpty {
                                albumFilterMenu
                            }
                        }
                        .padding(.horizontal, 20)

                        SearchBar(text: $searchText, onSearch: {
                            executeSearch(query: searchText)
                        })
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                    }
                    .background(Color.black)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 20) {
                            if !searchText.isEmpty {
                                searchResultsSection
                            } else {
                                albumSections
                            }

                            Color.clear.frame(height: 20)
                        }
                        .padding(.top, 10)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }

                if isPreparingCustomAlbum {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.2)
                        Text("Finding photos for your album...")
                            .foregroundColor(.white)
                            .font(.system(size: 15, weight: .medium))
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .background(Color(white: 0.15))
                    .cornerRadius(18)
                }
            }
            .dismissKeyboardOnTap()
            .navigationDestination(item: $customAlbumDraft) { draft in
                CustomAlbumDraftView(draft: draft) {
                    loadCategories()
                }
            }
        }
        .sheet(item: $selectedResultAssetId) { assetItem in
            PhotoDetailModal(assetId: assetItem.id)
        }
        .sheet(isPresented: $showCreateCustomAlbumSheet) {
            CustomAlbumNamePromptView(
                albumName: $pendingCustomAlbumName,
                errorMessage: customAlbumErrorMessage,
                onCancel: {
                    pendingCustomAlbumName = ""
                    customAlbumErrorMessage = ""
                    showCreateCustomAlbumSheet = false
                },
                onSubmit: submitCustomAlbumName
            )
            .presentationDetents([.fraction(0.32)])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            loadCategories()
            if !hasAutoScanned && !syncVM.isSyncing {
                hasAutoScanned = true
                syncVM.startSync()
            }
        }
        .onChange(of: syncVM.syncedCount) { _, _ in
            refreshAllPhotosIfNeeded()
            loadPrimaryAlbumSections()
        }
        .onChange(of: syncVM.isSyncing) { _, isNowSyncing in
            if !isNowSyncing && syncVM.syncedCount > 0 {
                syncBannerCount = syncVM.syncedCount
                withAnimation { showSyncBanner = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { showSyncBanner = false }
                }
            }

            if !isNowSyncing {
                refreshMetadataAlbumsIfNeeded(force: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DatabaseUpdated"))) { _ in
            loadCategories()
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty {
                searchResults = []
                hasSearched = false
                isSearching = false
                searchTask?.cancel()
            } else {
                hasSearched = false
                searchResults = []
            }
        }
        .onChange(of: pendingCustomAlbumName) { _, _ in
            customAlbumErrorMessage = ""
        }
        .onChange(of: currentMode) { _, _ in
                    refreshAllPhotosIfNeeded()
                    refreshMetadataAlbumsIfNeeded()
                }
        // 🌟 正確放置的 Delete Album Alert
        .alert("Delete Album", isPresented: $showDeleteAlbumAlert) {
            Button("Delete", role: .destructive) {
                if let id = targetAlbumId {
                    if isCustomAlbumTarget {
                        DatabaseManager.shared.deleteCustomAlbum(albumId: id)
                    }
                    loadCategories()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this album? The photos inside will not be deleted from your device.")
        }
    }
    
    private var allPhotosSectionView: some View {
        VStack(spacing: 0) {
            if isLoadingAllPhotos && allPhotos.isEmpty {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .padding(.top, 40)
            } else {
                LazyVGrid(columns: fiveColumnGrid, spacing: 2) {
                    ForEach(allPhotos) { photo in
                        Button(action: {
                            selectedResultAssetId = IdentifiableString(id: photo.id)
                        }) {
                            PhotoThumbnailView(assetId: photo.id)
                                .aspectRatio(1, contentMode: .fill)
                                .clipped()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var searchResultsSection: some View {
        Group {
            if !hasSearched {
                VStack(spacing: 8) {
                    Image(systemName: "return")
                        .font(.system(size: 28))
                        .foregroundColor(.white.opacity(0.25))
                    Text("Press Return to search")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else if isSearching {
                VStack(spacing: 15) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.2)
                    Text("Analyzing...")
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 50)
            } else if searchResults.isEmpty {
                Text("No matches found")
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 15
                ) {
                    ForEach(searchResults, id: \.self) { assetId in
                        Button(action: {
                            selectedResultAssetId = IdentifiableString(id: assetId)
                        }) {
                            PhotoThumbnailView(assetId: assetId)
                                .frame(height: 170)
                                .cornerRadius(12)
                                .clipped()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var albumSections: some View {
            VStack(alignment: .leading, spacing: 20) {
                if displayedAlbumSectionCount == 0 && !syncVM.isSyncing {
                    Text("No Albums Found")
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    switch currentMode {
                    case .allPhotos:
                        allPhotosSectionView
                    case .dictionary:
                        dictionaryAlbumSectionsView
                    case .metadata:
                        if isLoadingMetadataAlbums && metadataAlbumSections.isEmpty {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                Text("Loading journeys...")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.65))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                        } else {
                            metadataAlbumSectionsView
                        }
                    }
                    
                    customAlbumsSectionView
                }
            }
        }

        private var displayedAlbumSectionCount: Int {
            switch currentMode {
            case .allPhotos:
                return allPhotos.isEmpty ? 0 : 1
            case .dictionary:
                let dictionaryCount = groupedCategories.reduce(0) { count, group in
                    count + (categorySummaries(for: group.subs).isEmpty ? 0 : 1)
                }
                return dictionaryCount + 1
            case .metadata:
                let metadataCount = metadataAlbumSections.reduce(0) { $0 + ($1.albums.isEmpty ? 0 : 1) }
                return metadataCount + 1
            }
        }

    private var albumFilterMenu: some View {
            Menu {
                ForEach(DashboardGalleryMode.allCases) { mode in
                    Button(action: {
                        currentMode = mode
                    }) {
                        HStack {
                            Text(mode.rawValue)
                            Spacer()
                            if currentMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(currentMode.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.75))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.12))
                .cornerRadius(999)
            }
        }

    private var dictionaryAlbumSectionsView: some View {
        ForEach(groupedCategories, id: \.main) { group in
            let subAlbums = categorySummaries(for: group.subs)
            if !subAlbums.isEmpty {
                VStack(alignment: .leading, spacing: 15) {
                    NavigationLink(
                        destination: GroupAlbumListView(
                            groupTitle: group.main,
                            subAlbums: subAlbums,
                            syncVM: syncVM
                        )
                    ) {
                        HStack {
                            Text(group.main.capitalized)
                                .font(.custom("SF Pro Text", size: 24).weight(.heavy))
                                .foregroundColor(.white)

                            Spacer()

                            HStack(spacing: 6) {
                                Text("View all")
                                    .font(.system(size: 13, weight: .semibold))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(.white.opacity(0.75))
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 15) {
                            ForEach(subAlbums) { album in
                                NavigationLink(
                                    destination: CategoryDetailView(
                                        categoryTitle: album.title,
                                        syncVM: syncVM
                                    )
                                ) {
                                    CategoryAlbumCard(album: album)
                                        .id(album.coverAssetId ?? album.id)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(action: {
                                        DatabaseManager.shared.togglePinCategory(keyword: album.id)
                                        loadCategories()
                                    }) {
                                        Label("Pin / Unpin", systemImage: "pin")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                }
                .background(Color(white: 0.15))
                .cornerRadius(16)
                .padding(.horizontal, 20)
            }
        }
    }

    private var metadataAlbumSectionsView: some View {
        ForEach(metadataAlbumSections) { section in
            if !section.albums.isEmpty {
                VStack(alignment: .leading, spacing: 15) {
                    NavigationLink(
                        destination: MetadataAlbumListView(
                            title: section.title,
                            albums: section.albums,
                            syncVM: syncVM
                        )
                    ) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(section.title)
                                    .font(.custom("SF Pro Text", size: 24).weight(.heavy))
                                    .foregroundColor(.white)
                                Text(section.id == "other-metadata" ? "Downloaded photos show filename/source hints here." : "Grouped from photo time and place metadata.")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.55))
                            }

                            Spacer()

                            HStack(spacing: 6) {
                                Text("View all")
                                    .font(.system(size: 13, weight: .semibold))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(.white.opacity(0.75))
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 15) {
                            ForEach(section.albums) { album in
                                NavigationLink(
                                    destination: CategoryDetailView(
                                        metadataAlbum: album,
                                        syncVM: syncVM
                                    )
                                ) {
                                    MetadataAlbumCard(album: album)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                }
                .background(Color(white: 0.15))
                .cornerRadius(16)
                .padding(.horizontal, 20)
            }
        }
    }

    private var customAlbumsSectionView: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Custom Albums")
                    .font(.custom("SF Pro Text", size: 24).weight(.heavy))
                    .foregroundColor(.white)

                Spacer()

                if !customAlbums.isEmpty {
                    NavigationLink(
                        destination: CustomAlbumListView(customAlbums: customAlbums, syncVM: syncVM)
                    ) {
                        HStack(spacing: 6) {
                            Text("View all")
                                .font(.system(size: 13, weight: .semibold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.white.opacity(0.75))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 15) {
                    Button(action: {
                        pendingCustomAlbumName = ""
                        showCreateCustomAlbumSheet = true
                    }) {
                        AddCustomAlbumCard()
                    }
                    .buttonStyle(.plain)

                    ForEach(customAlbums) { album in
                        NavigationLink(
                            destination: CategoryDetailView(customAlbum: album, syncVM: syncVM)
                        ) {
                            CustomAlbumCard(album: album)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(action: {
                                DatabaseManager.shared.togglePinCustomAlbum(albumId: album.id)
                                loadCategories()
                            }) {
                                Label("Pin / Unpin", systemImage: "pin")
                            }

                            Button(role: .destructive, action: {
                                targetAlbumId = album.id
                                isCustomAlbumTarget = true
                                showDeleteAlbumAlert = true
                            }) {
                                Label("Delete Album", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(Color(white: 0.15))
        .cornerRadius(16)
        .padding(.horizontal, 20)
    }

    private func loadCategories() {
        refreshAllPhotosIfNeeded()
        loadPrimaryAlbumSections()
        refreshMetadataAlbumsIfNeeded(force: metadataAlbumSections.isEmpty)
    }

    private func loadPrimaryAlbumSections() {
        groupedCategories = DatabaseManager.shared.fetchGroupedCategories()
        customAlbums = DatabaseManager.shared.fetchCustomAlbums()
    }

    private func shouldLoadMetadataAlbums() -> Bool {
            currentMode == .allPhotos || currentMode == .metadata
        }
    
    private func refreshAllPhotosIfNeeded() {
        guard currentMode == .allPhotos else { return }
        isLoadingAllPhotos = true
        Task {
            let photos = await Task.detached(priority: .userInitiated) {
                DatabaseManager.shared.fetchAllPhotosWithDetails()
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.allPhotos = photos
                self.isLoadingAllPhotos = false
            }
        }
    }

    private func refreshMetadataAlbumsIfNeeded(force: Bool = false) {
        guard shouldLoadMetadataAlbums() || force else { return }
        loadMetadataAlbumSections()
    }

    private func loadMetadataAlbumSections() {
        metadataLoadTask?.cancel()
        isLoadingMetadataAlbums = true
        metadataLoadTask = Task {
            let sections = await Task.detached(priority: .userInitiated) {
                DatabaseManager.shared.fetchMetadataAlbumSections()
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                metadataAlbumSections = sections
                isLoadingMetadataAlbums = false
                metadataLoadTask = nil
            }
        }
    }

    private func executeSearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            hasSearched = false
            return
        }

        hasSearched = true
        isSearching = true
        searchTask = Task {
            let results = await Task.detached(priority: .userInitiated) {
                SemanticPhotoSearch.search(query: trimmed)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                searchResults = results
                isSearching = false
            }
        }
    }

    private func submitCustomAlbumName() {
        let trimmed = pendingCustomAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            customAlbumErrorMessage = "Please enter an album name."
            return
        }

        guard !DatabaseManager.shared.customAlbumExists(named: trimmed) else {
            customAlbumErrorMessage = "An album named \"\(trimmed)\" already exists."
            return
        }

        showCreateCustomAlbumSheet = false
        pendingCustomAlbumName = ""
        isPreparingCustomAlbum = true

        Task {
            let results = await Task.detached(priority: .userInitiated) {
                SemanticPhotoSearch.search(query: trimmed)
            }.value

            await MainActor.run {
                isPreparingCustomAlbum = false
                customAlbumDraft = CustomAlbumDraft(title: trimmed, initialAssetIds: results)
            }
        }
    }

    private func categorySummaries(for subCategories: [String]) -> [CategoryAlbumSummary] {
        subCategories.map { subCategory in
            let assetIds = DatabaseManager.shared.fetchPhotos(for: subCategory)
            return CategoryAlbumSummary(
                id: subCategory,
                title: subCategory,
                coverAssetId: assetIds.first,
                photoCount: assetIds.count
            )
        }
        .filter { $0.photoCount > 0 }
    }
}

private struct CategoryAlbumSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let coverAssetId: String?
    let photoCount: Int
}

private struct CustomAlbumDraft: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let initialAssetIds: [String]
}

private struct AddCustomAlbumCard: View {
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.28))
                    .frame(width: 160, height: 160)

                Image(systemName: "plus")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.white)
            }

            Text("New Album")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
        }
    }
}

private struct CategoryAlbumCard: View {
    let album: CategoryAlbumSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AlbumCoverView(assetId: album.coverAssetId)

            Text(album.title.capitalized)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            Text("\(album.photoCount) photos")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
        }
        .frame(width: 160, alignment: .leading)
    }
}

private struct CustomAlbumCard: View {
    let album: CustomAlbumSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AlbumCoverView(assetId: album.coverAssetId)

            Text(album.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            Text("\(album.photoCount) photos")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
        }
        .frame(width: 160, alignment: .leading)
    }
}

private struct MetadataAlbumCard: View {
    let album: MetadataAlbumSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AlbumCoverView(assetId: album.coverAssetId)

            Text(album.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)

            Text(album.subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(2)
                .frame(minHeight: 32, alignment: .topLeading)

            Text("\(album.photoCount) photos")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
        }
        .frame(width: 160, alignment: .leading)
    }
}

private struct GroupAlbumListView: View {
    let groupTitle: String
    let subAlbums: [CategoryAlbumSummary]
    @ObservedObject var syncVM: PhotoSyncViewModel

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(groupTitle.capitalized)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.top, 12)

                    Text("\(subAlbums.count) albums")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))

                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(subAlbums) { album in
                            NavigationLink(
                                destination: CategoryDetailView(
                                    categoryTitle: album.title,
                                    syncVM: syncVM
                                )
                            ) {
                                CategoryAlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }
}

private struct MetadataAlbumListView: View {
    let title: String
    let albums: [MetadataAlbumSummary]
    @ObservedObject var syncVM: PhotoSyncViewModel

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.top, 12)

                    Text("\(albums.count) albums")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))

                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(albums) { album in
                            NavigationLink(
                                destination: CategoryDetailView(metadataAlbum: album, syncVM: syncVM)
                            ) {
                                MetadataAlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }
}

private struct CustomAlbumNamePromptView: View {
    @Binding var albumName: String
    let errorMessage: String
    let onCancel: () -> Void
    let onSubmit: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                Text("Create Custom Album")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)

                Text("Type the album name and we'll preselect matching photos for you.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))

                TextField("Album name", text: $albumName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(12)
                    .foregroundColor(.white)
                    .focused($isFocused)
                    .onSubmit {
                        onSubmit()
                    }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.red.opacity(0.9))
                }

                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(12)
                    }

                    Button(action: onSubmit) {
                        Text("Continue")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white)
                            .cornerRadius(12)
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                isFocused = true
            }
        }
    }
}

private struct CustomAlbumDraftView: View {
    @Environment(\.dismiss) private var dismiss

    let draft: CustomAlbumDraft
    let onCreated: () -> Void

    @State private var selectedAssetIds: Set<String>
    @State private var selectedPreviewAssetId: IdentifiableString? = nil
    @State private var isCreating = false
    @State private var errorMessage = ""

    init(draft: CustomAlbumDraft, onCreated: @escaping () -> Void) {
        self.draft = draft
        self.onCreated = onCreated
        self._selectedAssetIds = State(initialValue: Set(draft.initialAssetIds))
    }

    private var orderedSelectedAssetIds: [String] {
        draft.initialAssetIds.filter { selectedAssetIds.contains($0) }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 18) {
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                    }

                    Spacer()

                    VStack(spacing: 4) {
                        Text(draft.title)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text("\(orderedSelectedAssetIds.count) selected")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.65))
                    }

                    Spacer()

                    Button(action: createAlbum) {
                        if isCreating {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                .frame(width: 28, height: 28)
                        } else {
                            Text(orderedSelectedAssetIds.isEmpty ? "Create Empty" : "Create")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.black)
                        }
                    }
                    .disabled(isCreating)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white)
                    .cornerRadius(999)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)

                VStack(alignment: .leading, spacing: 12) {
                    Text("All matching photos are selected by default. Tap any photo to remove or add it back before creating the album.")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Button(action: {
                        if selectedAssetIds.count == draft.initialAssetIds.count {
                            selectedAssetIds.removeAll()
                        } else {
                            selectedAssetIds = Set(draft.initialAssetIds)
                        }
                    }) {
                        Text(selectedAssetIds.count == draft.initialAssetIds.count ? "Deselect All" : "Select All")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 20)

                if draft.initialAssetIds.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 34))
                            .foregroundColor(.white.opacity(0.45))
                        Text("No matching photos found")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                        Text("You can still create an empty album, or go back and try another name.")
                            .font(.system(size: 14))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.horizontal, 28)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 15) {
                            ForEach(draft.initialAssetIds, id: \.self) { assetId in
                                Button(action: {
                                    toggleSelection(for: assetId)
                                }) {
                                    ZStack(alignment: .topTrailing) {
                                        PhotoThumbnailView(assetId: assetId)
                                            .frame(height: 170)
                                            .cornerRadius(14)
                                            .clipped()
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 14)
                                                    .fill(Color.black.opacity(selectedAssetIds.contains(assetId) ? 0.04 : 0.45))
                                            }

                                        Image(systemName: selectedAssetIds.contains(assetId) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 24, weight: .semibold))
                                            .foregroundColor(selectedAssetIds.contains(assetId) ? .white : .white.opacity(0.75))
                                            .padding(10)
                                    }
                                }
                                .contextMenu {
                                    Button(action: {
                                        selectedPreviewAssetId = IdentifiableString(id: assetId)
                                    }) {
                                        Label("Preview", systemImage: "eye")
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .sheet(item: $selectedPreviewAssetId) { assetItem in
            PhotoDetailModal(assetId: assetItem.id)
        }
        .alert("Unable to create album", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { !errorMessage.isEmpty },
            set: { isPresented in
                if !isPresented {
                    errorMessage = ""
                }
            }
        )
    }

    private func toggleSelection(for assetId: String) {
        if selectedAssetIds.contains(assetId) {
            selectedAssetIds.remove(assetId)
        } else {
            selectedAssetIds.insert(assetId)
        }
    }

    private func createAlbum() {
        guard !DatabaseManager.shared.customAlbumExists(named: draft.title) else {
            errorMessage = "An album named \"\(draft.title)\" already exists."
            return
        }

        isCreating = true
        let albumId = DatabaseManager.shared.createCustomAlbum(title: draft.title, assetIds: orderedSelectedAssetIds)
        isCreating = false

        guard albumId != nil else {
            errorMessage = "The album could not be created right now."
            return
        }

        onCreated()
        dismiss()
    }
}

// MARK: - 相簿封面元件
struct AlbumCoverView: View {
    let assetId: String?
    @State private var image: UIImage? = nil
    @State private var isMissing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.3))
                .frame(width: 160, height: 160)

            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 160, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .transition(.opacity)
            } else if isMissing {
                Image(systemName: "photo.slash")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .onAppear { loadImage() }
        .onChange(of: assetId) { _, _ in loadImage() }
        .animation(.easeInOut(duration: 0.3), value: image)
    }

    private func loadImage() {
        guard let assetId = assetId else {
            image = nil
            isMissing = true
            return
        }

        image = nil
        isMissing = false
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = fetchResult.firstObject else {
            isMissing = true
            return
        }
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        manager.requestImage(
            for: asset,
            targetSize: CGSize(width: 280, height: 360),
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            if let result = result {
                DispatchQueue.main.async {
                    image = result
                    isMissing = false
                }
            } else {
                DispatchQueue.main.async {
                    image = nil
                    isMissing = true
                }
            }
        }
    }
}

struct CustomAlbumListView: View {
    let customAlbums: [CustomAlbumSummary]
    @ObservedObject var syncVM: PhotoSyncViewModel
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Custom Albums")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.top, 12)

                    Text("\(customAlbums.count) albums")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))

                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(customAlbums) { album in
                            NavigationLink(
                                destination: CategoryDetailView(customAlbum: album, syncVM: syncVM)
                            ) {
                                CustomAlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }
}
