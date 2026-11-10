import UIKit

/// Warms UIKit's date picker once, so the first wheel a user opens does not stall on its first drag.
///
/// The picker is laid out in no window and dropped. A hidden SwiftUI `DatePicker` used to do this from inside each date
/// block, and UIKit drew its selected row, today's date, faintly beside the field at any opacity above zero.
enum DatePickerPrewarmer {
    private(set) static var hasRun = false

    static func prewarmOnce() {
        guard !hasRun else { return }
        hasRun = true
        DispatchQueue.main.async {
            let picker = UIDatePicker(frame: CGRect(x: 0, y: 0, width: 320, height: 216))
            picker.datePickerMode = .dateAndTime
            picker.preferredDatePickerStyle = .wheels
            picker.setNeedsLayout()
            picker.layoutIfNeeded()
        }
    }
}
