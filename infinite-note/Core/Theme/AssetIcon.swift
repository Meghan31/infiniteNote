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

    var body: some View {
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
}
