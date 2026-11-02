//
//  KeepAwake.swift
//  SuperMinimalTools
//

import Foundation
import IOKit.pwr_mgt
import Observation

/// Keeps the display (and so the Mac) from sleeping while idle, for a number
/// of minutes or until turned off.
///
/// Holds an IOKit power assertion, which the system drops by itself if the
/// app quits, so nothing is left behind. Never restored on relaunch.
@Observable
@MainActor
final class KeepAwake {

    /// When the assertion is released; `nil` while on indefinitely.
    private(set) var endDate: Date?
    private(set) var isActive = false

    @ObservationIgnored private var assertionID: IOPMAssertionID = 0
    @ObservationIgnored private var timerTask: Task<Void, Never>?

    /// Starts keeping the screen on, replacing any earlier choice.
    /// `minutes == nil` keeps it on until `stop()`.
    func start(minutes: Int?) {
        if let minutes, minutes <= 0 { return }
        if !isActive {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "SuperMinimalTools: Keep Screen On" as CFString,
                &assertionID
            )
            guard result == kIOReturnSuccess else { return }
            isActive = true
        }

        timerTask?.cancel()
        timerTask = nil
        guard let minutes else {
            endDate = nil
            return
        }
        let duration = Duration.seconds(minutes * 60)
        endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        // The continuous clock keeps counting while the Mac sleeps, so a lid
        // closed past the end time still turns it off on wake.
        let deadline = ContinuousClock.now + duration
        timerTask = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        endDate = nil
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
    }

    /// "Off in 1:05" style countdown for the dropdown.
    nonisolated static func remainingText(until endDate: Date, now: Date) -> String {
        let seconds = max(0, Int(endDate.timeIntervalSince(now).rounded(.up)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
