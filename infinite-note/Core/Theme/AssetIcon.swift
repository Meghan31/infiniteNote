import SwiftUI
import UIKit

// MARK: - Asset Icon
//
// Renders a downloaded image from the asset catalog when it exists (in full
// color), otherwise falls back to an SF Symbol tinted with the given color.
// Used for the custom toolbar icons (home, sidebars, scale, download, share,
// sync) so they degrade gracefully until the artwork is added to Assets.

struct AssetIcon: View {
    let asset: String
    let systemName: String
    var size: CGFloat = 22
    var fallbackTint: Color = .primary
    var symbolWeight: Font.Weight = .semibold
    var addsDepth: Bool = true

    var body: some View {
        Group {
            if UIImage(named: asset) != nil {
                Image(asset)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.82, weight: symbolWeight))
                    .foregroundStyle(fallbackTint)
                    .frame(width: size, height: size)
            }
        }
        .shadow(color: addsDepth ? .white.opacity(0.62) : .clear, radius: 0, x: -0.8, y: -0.8)
        .shadow(color: addsDepth ? Color(red: 0.08, green: 0.09, blue: 0.14).opacity(0.56) : .clear, radius: 0, x: 2.6, y: 3.4)
        .shadow(color: addsDepth ? .black.opacity(0.36) : .clear, radius: 2.6, x: 3.4, y: 4.4)
        .shadow(color: addsDepth ? .black.opacity(0.20) : .clear, radius: 7, x: 4.2, y: 6)
    }
}
