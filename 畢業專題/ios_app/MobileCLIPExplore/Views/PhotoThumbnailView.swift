import SwiftUI
import Photos

struct PhotoThumbnailView: View {
    let assetId: String
    @State private var image: UIImage? = nil
    @State private var isUnavailable = false
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if isUnavailable {
                ZStack {
                    Color.gray.opacity(0.18)
                    Image(systemName: "photo.slash")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))
                }
            } else {
                Color.gray.opacity(0.3)
            }
        }

        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .onAppear {
            fetchImage()
        }
    }
    
    private func fetchImage() {
        image = nil
        isUnavailable = false
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = fetchResult.firstObject else {
            isUnavailable = true
            return
        }
        
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true // 允許從 iCloud 下載
        options.deliveryMode = .opportunistic // 先給低畫質，再給高畫質
        
        manager.requestImage(for: asset, targetSize: CGSize(width: 250, height: 250), contentMode: .aspectFill, options: options) { result, _ in
            if let result = result {
                DispatchQueue.main.async {
                    self.image = result
                    self.isUnavailable = false
                }
            } else {
                DispatchQueue.main.async {
                    self.image = nil
                    self.isUnavailable = true
                }
            }
        }
    }
}
