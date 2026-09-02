import Foundation

/// Resolves an ordered list of sections into concrete rectangles.
///
/// Deliberately free of AppKit drawing so the geometry can be tested directly.
/// `DashboardView` owns one of these and rebuilds it when the order or the view
/// width changes; every draw and invalidation path reads it rather than
/// repeating coordinates. That is the point: the same six y values were
/// previously typed out in four separate places, which is why nothing could
/// move without them drifting apart.
struct DashboardLayout {
    struct Slot {
        let section: DashboardSection
        let rect: NSRect
    }

    static let margin: CGFloat = 12
    static let gap: CGFloat = 10
    /// The header band is drawn at the origin; content clears it by 14pt.
    static let headerHeight: CGFloat = 68
    static let contentTop: CGFloat = 82
    static let selfHeight: CGFloat = 42
    static let footerGap: CGFloat = 14
    static let footerHeight: CGFloat = 38
    /// Trailing slack below the footer, preserved from the document height of
    /// 1120 that the view used to carry as a literal.
    static let bottomPadding: CGFloat = 20

    let slots: [Slot]
    let selfRect: NSRect
    let footerRect: NSRect
    let contentHeight: CGFloat

    func rect(for section: DashboardSection) -> NSRect? {
        slots.first { $0.section == section }?.rect
    }

    static func make(order: [DashboardSection], width: CGFloat) -> DashboardLayout {
        let sections = DashboardSection.normalized(order)
        let fullWidth = width - margin * 2
        let halfWidth = (fullWidth - gap) / 2
        let rightX = margin + halfWidth + gap

        var slots: [Slot] = []
        var y = contentTop
        // Height of the half-width row currently being filled, or nil when no
        // row is open. A full-width section closes an open row and leaves the
        // orphaned half of it empty, which is why the document height depends
        // on the order and not only on the set of sections.
        var openRowHeight: CGFloat?

        for section in sections {
            if section.isFullWidth {
                if let rowHeight = openRowHeight {
                    y += rowHeight + gap
                    openRowHeight = nil
                }
                slots.append(Slot(
                    section: section,
                    rect: NSRect(x: margin, y: y, width: fullWidth, height: section.height)
                ))
                y += section.height + gap
            } else if let rowHeight = openRowHeight {
                slots.append(Slot(
                    section: section,
                    rect: NSRect(x: rightX, y: y, width: halfWidth, height: section.height)
                ))
                y += max(rowHeight, section.height) + gap
                openRowHeight = nil
            } else {
                slots.append(Slot(
                    section: section,
                    rect: NSRect(x: margin, y: y, width: halfWidth, height: section.height)
                ))
                openRowHeight = section.height
            }
        }
        if let rowHeight = openRowHeight {
            y += rowHeight + gap
        }

        let selfRect = NSRect(x: margin, y: y, width: fullWidth, height: selfHeight)
        let footerRect = NSRect(
            x: 0,
            y: selfRect.maxY + footerGap,
            width: width,
            height: footerHeight
        )
        return DashboardLayout(
            slots: slots,
            selfRect: selfRect,
            footerRect: footerRect,
            contentHeight: footerRect.maxY + bottomPadding
        )
    }

    /// The index the dragged section should take if dropped at `point`.
    ///
    /// Measured against slot midpoints in reading order, so the answer is
    /// stable for full-width and half-width slots alike.
    func insertionIndex(for point: NSPoint, excluding dragged: DashboardSection) -> Int {
        var index = 0
        for slot in slots where slot.section != dragged {
            let midY = slot.rect.midY
            let isPastVertically = point.y > midY
            let isSameRowAndPastHorizontally = abs(point.y - midY) <= slot.rect.height / 2
                && point.x > slot.rect.midX
            if isPastVertically || isSameRowAndPastHorizontally {
                index += 1
            }
        }
        return index
    }
}
