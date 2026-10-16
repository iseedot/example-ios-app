//
//  LogSharing.swift
//  MyCallRec — hand the run log to the system share sheet.
//
//  The log already lives at Documents/logs/MyCallRec.log, which the Files app should
//  show because the bundle sets UIFileSharingEnabled. That is not reliable enough when
//  the whole point is to get the file out of the device, so the app can present the
//  share sheet itself, anchored for iPad as well as iPhone.
//

import UIKit

enum LogSharing {
    static func present(items: [Any]) {
        guard !items.isEmpty else { return }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }),
            let root = window.rootViewController else {
            trlog(.error, "APP", "找不到窗口，无法弹出分享面板")
            return
        }

        var top = root
        while let presented = top.presentedViewController { top = presented }

        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad requires a popover anchor; without it the presentation raises.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY,
                                        width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
}
