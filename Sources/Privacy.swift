//
//  Privacy.swift
//  MyCallRec — mask personal data before a log leaves the device.
//
//  What the run log actually contains: the number of every call the watcher saw, the contact
//  name when one resolves, recording paths, the app container UUID, process pids and bundle
//  identifiers. It does NOT contain a UDID, a serial number, an Apple ID or the user-assigned
//  device name, and Diagnostics no longer collects that name either.
//
//  A phone number and a contact name are still personal data, so the clipboard copy can mask
//  them: phone-like digit runs keep only the last four digits, a 名称 value is replaced, and
//  the device name is removed if it ever appears.
//

import Foundation
import UIKit

enum Privacy {
    static func redact(_ text: String) -> String {
        var result = text

        // Phone-like digit runs (at least seven digits). Four last digits stay so a call is
        // still recognisable; pids and timestamps are far shorter or have separators.
        if let regex = try? NSRegularExpression(pattern: "\\d{7,}") {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            for match in regex.matches(in: result, range: range).reversed() {
                guard let swiftRange = Range(match.range, in: result) else { continue }
                let digits = result[swiftRange]
                let tail = String(digits.suffix(4))
                result.replaceSubrange(swiftRange,
                                       with: String(repeating: "*", count: max(0, digits.count - 4)) + tail)
            }
        }

        // Contact display name in the call-event line.
        if let regex = try? NSRegularExpression(pattern: "名称=\\S+") {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range,
                                                    withTemplate: "名称=「已隐藏」")
        }

        let deviceName = UIDevice.current.name
        if !deviceName.isEmpty {
            result = result.replacingOccurrences(of: deviceName, with: "「设备名已隐藏」")
        }
        return result
    }
}
