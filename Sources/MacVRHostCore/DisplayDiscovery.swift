import CoreGraphics
import Foundation

public struct DisplayDescriptor: Sendable {
    public let id: UInt32
    public let width: Int
    public let height: Int
    public let refreshRateHz: Double
    public let isMain: Bool

    public init(id: UInt32, width: Int, height: Int, refreshRateHz: Double, isMain: Bool) {
        self.id = id
        self.width = width
        self.height = height
        self.refreshRateHz = refreshRateHz
        self.isMain = isMain
    }
}

public enum DisplayDiscovery {
    public static func activeDisplays() -> [DisplayDescriptor] {
        var count: UInt32 = 0
        let countStatus = CGGetActiveDisplayList(0, nil, &count)
        guard countStatus == .success, count > 0 else {
            return []
        }

        var displayIDs = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        let listStatus = CGGetActiveDisplayList(count, &displayIDs, &count)
        guard listStatus == .success else {
            return []
        }

        let mainDisplay = CGMainDisplayID()
        return displayIDs.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let refresh = mode?.refreshRate ?? 0.0
            return DisplayDescriptor(
                id: UInt32(id),
                width: Int(bounds.width),
                height: Int(bounds.height),
                refreshRateHz: refresh,
                isMain: id == mainDisplay
            )
        }
    }
}
