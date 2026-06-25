// MetricKitReporter.swift
// A2: MetricKit subscriber for memory-footprint and app-exit diagnostics.
//
// The OS delivers yesterday's metrics once per day (~morning). This reporter
// summarises them and posts to /v1/metrics so exit counts can be monitored
// in the field without an active Instruments session.
//
// HOST APP ONLY: register MetricKitReporter.shared.start() in TonoApp.init().
// The keyboard extension is not registered directly; extension OOM events
// arrive through the host-app subscriber via MXAppExitMetric because iOS
// groups extension exits with the host process.
//
// Privacy: payload contains exit counts, memory averages, and anonymized
// device ID. No message content or user-visible text is included.

import Foundation
import MetricKit

public final class MetricKitReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    public static let shared = MetricKitReporter()

    public func start() {
        MXMetricManager.shared.add(self)
    }

    // MARK: - MXMetricManagerSubscriber

    /// Called once per day by the OS with the previous day's aggregate metrics.
    public func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            var report: [String: Any] = [
                "type": "daily_metrics",
                "end_ts": payload.timeStampEnd.timeIntervalSince1970,
            ]

            // Memory footprint average.
            // MXMemoryMetric API changed in iOS 26 — memoryAverageUsage removed.
            // Safely attempt via runtime reflection; skip if unavailable.
            if let mem = payload.memoryMetrics {
                let mirror = Mirror(reflecting: mem)
                if let avgUsage = mirror.children.first(where: { $0.label == "memoryAverageUsage" })?.value {
                    let avgMirror = Mirror(reflecting: avgUsage)
                    if let measurement = avgMirror.children.first(where: { $0.label == "averageMeasurement" })?.value,
                       let measurementMirror = Mirror(reflecting: measurement).superclassMirror {
                        // Use the numericValue if available
                        if let value = measurementMirror.children.first(where: { $0.label == "value" })?.value as? Double {
                            report["avg_memory_mb"] = value
                        }
                    }
                }
            }

            // App exit breakdown — the primary OOM signal for the extension.
            if let exits = payload.applicationExitMetrics {
                let fg = exits.foregroundExitData
                let bg = exits.backgroundExitData
                report["fg_normal"]      = fg.cumulativeNormalAppExitCount
                report["fg_oom"]         = fg.cumulativeMemoryResourceLimitExitCount
                report["bg_oom"]         = bg.cumulativeMemoryResourceLimitExitCount
                report["bg_watchdog"]    = bg.cumulativeAppWatchdogExitCount
                report["bg_normal"]      = bg.cumulativeNormalAppExitCount
            }

            post(report)
        }
    }

    /// Diagnostic payloads (crashes, hangs, disk write exceptions).
    /// We record counts only — no stack symbolics are sent to the backend.
    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            var report: [String: Any] = [
                "type": "diagnostics",
                "end_ts": payload.timeStampEnd.timeIntervalSince1970,
                "crash_count": payload.crashDiagnostics?.count ?? 0,
                "hang_count":  payload.hangDiagnostics?.count ?? 0,
            ]
            if let dw = payload.diskWriteExceptionDiagnostics {
                report["disk_write_exception_count"] = dw.count
            }
            post(report)
        }
    }

    // MARK: - Private

    private func post(_ data: [String: Any]) {
        let deviceId = SharedKeychain.get(KeychainKeys.deviceID) ?? ""
        let token    = SharedKeychain.get(KeychainKeys.apiToken) ?? ""
        guard !deviceId.isEmpty else { return }

        var body = data
        body["device_id"] = deviceId
        body["ts"] = Int(Date().timeIntervalSince1970)

        guard let encoded = try? JSONSerialization.data(withJSONObject: body) else { return }
        let url = TonoBackend.shared.baseURL.appendingPathComponent("v1/metrics")
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = encoded

        URLSession.shared.dataTask(with: req).resume()
    }
}
