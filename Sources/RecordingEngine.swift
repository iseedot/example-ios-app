//
//  RecordingEngine.swift
//  MyCallRec — what the app needs from whatever is recording right now.
//
//  A recording is either one private tap (manual target) or the two sides of a call held
//  together: the microphone for my side and the speaker tap for the other side. The two
//  sides cannot share one queue, so they are separate engines behind this protocol and the
//  app only ever talks to the protocol.
//

import Foundation

protocol RecordingEngine: AnyObject {
    /// The file the recording is presented as: the single file, or the merged call file.
    var fileURL: URL { get }
    var secondsRecorded: Double { get }
    var packetsWritten: UInt64 { get }
    var peakAmplitude: Float { get }
    var maxPeakAmplitude: Float { get }
    var receivedFirstBuffer: Bool { get }
    /// Human-readable target for the log and the metadata sidecar.
    var targetLabel: String { get }
    var startedAt: Date { get }
    func stop()
}
