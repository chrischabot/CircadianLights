import Foundation

struct BrightnessSchedule: Codable, Equatable {
    var timeSlots: [TimeSlot]

    struct TimeSlot: Codable, Identifiable, Equatable {
        let id: UUID
        var startHour: Int
        var startMinute: Int
        var endHour: Int
        var endMinute: Int
        var hueBrightness: Int      // 0-100%
        var elgatoBrightness: Int   // 0-100%

        var startTimeString: String {
            String(format: "%02d:%02d", startHour, startMinute)
        }

        var endTimeString: String {
            String(format: "%02d:%02d", endHour, endMinute)
        }

        func contains(hour: Int, minute: Int) -> Bool {
            let currentMinutes = hour * 60 + minute
            let startMinutes = startHour * 60 + startMinute
            let endMinutes = endHour * 60 + endMinute

            if startMinutes <= endMinutes {
                // Normal case: e.g., 09:00 to 17:00
                return currentMinutes >= startMinutes && currentMinutes < endMinutes
            } else {
                // Overnight case: e.g., 21:00 to 06:00
                return currentMinutes >= startMinutes || currentMinutes < endMinutes
            }
        }
    }

    func brightnessForCurrentTime() -> (hue: Int, elgato: Int) {
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)

        for slot in timeSlots {
            if slot.contains(hour: hour, minute: minute) {
                return (slot.hueBrightness, slot.elgatoBrightness)
            }
        }

        // Fallback to default values
        return (50, 50)
    }

    // MARK: - Default Schedule

    static let `default` = BrightnessSchedule(timeSlots: [
        TimeSlot(
            id: UUID(),
            startHour: 6, startMinute: 0,
            endHour: 9, endMinute: 0,
            hueBrightness: 70,
            elgatoBrightness: 50
        ),
        TimeSlot(
            id: UUID(),
            startHour: 9, startMinute: 0,
            endHour: 17, endMinute: 0,
            hueBrightness: 100,
            elgatoBrightness: 80
        ),
        TimeSlot(
            id: UUID(),
            startHour: 17, startMinute: 0,
            endHour: 21, endMinute: 0,
            hueBrightness: 60,
            elgatoBrightness: 30
        ),
        TimeSlot(
            id: UUID(),
            startHour: 21, startMinute: 0,
            endHour: 6, endMinute: 0,
            hueBrightness: 50,
            elgatoBrightness: 3
        )
    ])
}
