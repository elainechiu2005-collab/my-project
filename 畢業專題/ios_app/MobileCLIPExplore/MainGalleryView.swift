import SwiftUI

enum GalleryViewMode: String, CaseIterable {
    case allPhotos = "All Photos"
    case taxonomy = "AI Classification"
    case journey = "Time & Place"
}

struct MainGalleryView: View {
    @State private var currentMode: GalleryViewMode = .allPhotos
    @State private var allPhotos: [PhotoListItem] = []
    @State private var taxonomyGroups: [(main: String, subs: [String])] = []
    @State private var journeySections: [MetadataAlbumSection] = []
    
    // 一行五張的排版設定
    let fiveColumnGrid = Array(repeating: GridItem(.flexible(), spacing: 2), count: 5)
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("相簿檢視模式", selection: $currentMode) {
                    ForEach(GalleryViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .padding()
                
                ScrollView {
                    switch currentMode {
                    case .allPhotos:
                        allPhotosGridView
                    case .taxonomy:
                        taxonomyAlbumsView
                    case .journey:
                        journeyAlbumsView
                    }
                }
            }
            .navigationTitle(currentMode.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { loadData() }
        }
    }
    
    private var allPhotosGridView: some View {
        LazyVGrid(columns: fiveColumnGrid, spacing: 2) {
            ForEach(allPhotos) { photo in
                Color.gray.aspectRatio(1, contentMode: .fill).clipped() // 請替換成實際圖片元件
            }
        }
    }
    
    private var taxonomyAlbumsView: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(taxonomyGroups, id: \.main) { group in
                VStack(alignment: .leading) {
                    Text(group.main).font(.headline).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(group.subs, id: \.self) { subCategory in
                                VStack {
                                    Color.blue.frame(width: 100, height: 100).cornerRadius(8)
                                    Text(subCategory).font(.caption)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
    }
    
    private var journeyAlbumsView: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(journeySections) { section in
                VStack(alignment: .leading) {
                    Text(section.title).font(.headline).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(section.albums) { album in
                                NavigationLink(destination: JourneyDetailView(album: album)) {
                                    VStack(alignment: .leading) {
                                        Color.green.frame(width: 140, height: 140).cornerRadius(10)
                                        Text(album.title).font(.subheadline).bold().foregroundColor(.primary)
                                        Text(album.subtitle).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
    }
    
    private func loadData() {
        DispatchQueue.global(qos: .userInitiated).async {
            let photos = DatabaseManager.shared.fetchAllPhotosWithDetails()
            let taxonomy = DatabaseManager.shared.fetchGroupedCategories()
            let journeys = DatabaseManager.shared.fetchMetadataAlbumSections()
            DispatchQueue.main.async {
                self.allPhotos = photos
                self.taxonomyGroups = taxonomy
                self.journeySections = journeys
            }
        }
    }
}

// 旅程詳細頁面：區分「相機拍攝」與「下載照片」
struct JourneyDetailView: View {
    let album: MetadataAlbumSummary
    let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !album.primaryAssetIds.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("相機拍攝").font(.headline).padding(.horizontal)
                        LazyVGrid(columns: gridColumns, spacing: 2) {
                            ForEach(album.primaryAssetIds, id: \.self) { assetId in
                                Color.gray.aspectRatio(1, contentMode: .fill).clipped()
                            }
                        }
                    }
                }
                
                if !album.otherAssetIds.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("同時間的其他/下載照片").font(.headline).padding(.horizontal)
                        LazyVGrid(columns: gridColumns, spacing: 2) {
                            ForEach(album.otherAssetIds, id: \.self) { assetId in
                                Color.orange.aspectRatio(1, contentMode: .fill).clipped()
                            }
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(album.title)
    }
}
