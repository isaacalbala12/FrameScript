import Foundation
import Testing
@testable import FrameScriptCore

/// Regression tests for fix package WP3 that live in the UI-free core.
@Suite("WP3 OBS connection and speech defaults")
struct WP3CoreTests {
    // Item 11: the OBS settings sheet warns when the host is not this Mac.
    @Test func loopbackHostsAreRecognised() {
        for host in ["localhost", "LOCALHOST", "  localhost  ", "127.0.0.1", "127.1.2.3", "::1", "[::1]"] {
            #expect(
                OBSConnectionConfig(host: host).isLoopbackHost,
                "\(host) should be treated as loopback"
            )
        }
    }

    @Test func remoteHostsAreNotLoopback() {
        for host in ["192.168.1.20", "obs.example.com", "10.0.0.1", "0.0.0.0", "127.0.0", ""] {
            #expect(
                !OBSConnectionConfig(host: host).isLoopbackHost,
                "\(host) should warn as a remote host"
            )
        }
    }

    // Item 7 guard: OBS's normal STARTING event reports outputActive == false.
    // The controller must only latch a real STOPPED event.
    @Test func startingOutputStateIsNotRecording() {
        let starting = OBSRecordStateChanged(
            outputActive: false,
            outputState: .starting,
            outputPath: nil
        )
        #expect(!starting.isRecording)

        let started = OBSRecordStateChanged(
            outputActive: true,
            outputState: .started,
            outputPath: nil
        )
        #expect(started.isRecording)

        let stopped = OBSRecordStateChanged(
            outputActive: false,
            outputState: .stopped,
            outputPath: "/tmp/take.mov"
        )
        #expect(!stopped.isRecording)
        #expect(stopped.outputState == .stopped)
    }
}
