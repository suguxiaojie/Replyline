import AppKit
import SwiftUI

enum CardGeometry {
    static let minimum = CGSize(width: 80, height: 64)
    static let corner: CGFloat = 26

    static func photo(_ size: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return CGSize(width: maxWidth, height: maxHeight)
        }
        let scale = min(maxWidth / size.width, maxHeight / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    static func shell(photo: CGSize) -> CGSize {
        CGSize(width: max(minimum.width, photo.width + Frame.inset * 2),
               height: max(minimum.height, photo.height + Frame.inset * 2))
    }

    static func cornerRect(in bounds: CGRect, trailing: Bool, flipped: Bool) -> CGRect {
        let width = min(corner, bounds.width / 2)
        let height = min(corner, bounds.height)
        return CGRect(x: trailing ? bounds.maxX - width : bounds.minX,
                      y: flipped ? bounds.minY : bounds.maxY - height, width: width, height: height)
    }
}

/// Real type at the displayed size; the original text stays in the repository.
struct LineTextCard: View {
    let card: LibraryCard
    let size: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .foregroundStyle(Color(white: 0.08))
            Text(card.text).font(.system(size: 10.5)).lineSpacing(2)
                .lineLimit(size.height >= 86 ? 3 : 2).foregroundStyle(Color(white: 0.32))
            Spacer(minLength: 0)
        }
        .padding(8).frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color(red: 252 / 255, green: 252 / 255, blue: 251 / 255))
    }
}

struct LineCardFace: View {
    let item: Pegged
    var body: some View {
        let shell = PeggedView.cardSize(for: item.thumb.size)
        let inner = CGSize(width: shell.width - Frame.inset * 2, height: shell.height - Frame.inset * 2)
        Group {
            if let card = item.libraryCard, card.kind == .text {
                LineTextCard(card: card, size: inner)
            } else {
                let photo = PeggedView.photoSize(for: item.thumb.size)
                Image(nsImage: item.thumb).resizable().interpolation(.high)
                    .frame(width: photo.width, height: photo.height)
                    .frame(width: inner.width, height: inner.height)
            }
        }
    }
}
