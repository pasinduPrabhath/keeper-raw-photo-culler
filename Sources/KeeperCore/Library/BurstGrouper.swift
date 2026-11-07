import Foundation

public enum BurstGrouper {
    /// Groups shots into bursts. `dates` must be ascending; the result has one burst index per element.
    /// A new burst starts whenever the gap to the previous frame exceeds `maxGap` seconds.
    public static func assign(dates: [Date], maxGap: TimeInterval) -> [Int] {
        var ids: [Int] = []
        ids.reserveCapacity(dates.count)
        var current = -1
        var previous: Date?
        for date in dates {
            if let previous, date.timeIntervalSince(previous) <= maxGap {
                // same burst
            } else {
                current += 1
            }
            ids.append(current)
            previous = date
        }
        return ids
    }
}
