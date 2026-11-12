import Testing
@testable import FrameScriptCore

@Suite("Timecode")
struct TimecodeTests {
    @Test("Formats whole-second boundaries at every supported rate")
    func formatsWholeSeconds() {
        #expect(Timecode(frames: 0).string(rate: .fps25, dropFrame: false) == "00:00:00:00")
        #expect(Timecode(frames: 1).string(rate: .fps25, dropFrame: false) == "00:00:00:01")
        #expect(Timecode(frames: 25).string(rate: .fps25, dropFrame: false) == "00:00:01:00")
        #expect(Timecode(frames: 90_000).string(rate: .fps25, dropFrame: false) == "01:00:00:00")

        #expect(Timecode(frames: 24).string(rate: .fps24, dropFrame: false) == "00:00:01:00")
        #expect(Timecode(frames: 30).string(rate: .fps30, dropFrame: false) == "00:00:01:00")
        #expect(Timecode(frames: 50).string(rate: .fps50, dropFrame: false) == "00:00:01:00")
        #expect(Timecode(frames: 60).string(rate: .fps60, dropFrame: false) == "00:00:01:00")
        #expect(Timecode(frames: 24).string(rate: .fps23_976, dropFrame: false) == "00:00:01:00")
    }

    @Test("Parses non-drop timecode at every supported rate")
    func parsesNonDrop() {
        #expect(Timecode(string: "00:00:00:00", rate: .fps25)?.frames == 0)
        #expect(Timecode(string: "00:00:01:00", rate: .fps25)?.frames == 25)
        #expect(Timecode(string: "01:00:00:00", rate: .fps25)?.frames == 90_000)
        #expect(Timecode(string: "00:01:00:00", rate: .fps29_97)?.frames == 1_800)
        #expect(Timecode(string: "01:00:00:00", rate: .fps29_97)?.frames == 108_000)
        #expect(Timecode(string: "00:00:01:00", rate: .fps23_976)?.frames == 24)
        #expect(Timecode(string: "00:00:01:00", rate: .fps59_94)?.frames == 60)
    }

    @Test("Rejects malformed and out-of-range timecode")
    func rejectsMalformed() {
        #expect(Timecode(string: "", rate: .fps25) == nil)
        #expect(Timecode(string: "1:00:00:00", rate: .fps25) == nil)
        #expect(Timecode(string: "00:60:00:00", rate: .fps25) == nil)
        #expect(Timecode(string: "00:00:60:00", rate: .fps25) == nil)
        #expect(Timecode(string: "24:00:00:00", rate: .fps25) == nil)
        #expect(Timecode(string: "00:00:00:25", rate: .fps25) == nil)
        #expect(Timecode(string: "00:00:00:30", rate: .fps29_97) == nil)
        #expect(Timecode(string: "00:00:00;00", rate: .fps25) == nil)
    }

    @Test("29.97 drop frame skips labels at each minute boundary")
    func dropFrame29_97() {
        #expect(Timecode(frames: 0).string(rate: .fps29_97, dropFrame: true) == "00:00:00;00")
        #expect(Timecode(frames: 1_799).string(rate: .fps29_97, dropFrame: true) == "00:00:59;29")
        #expect(Timecode(frames: 1_800).string(rate: .fps29_97, dropFrame: true) == "00:01:00;02")
        #expect(Timecode(frames: 3_597).string(rate: .fps29_97, dropFrame: true) == "00:01:59;29")
        #expect(Timecode(frames: 3_598).string(rate: .fps29_97, dropFrame: true) == "00:02:00;02")
        #expect(Timecode(frames: 17_981).string(rate: .fps29_97, dropFrame: true) == "00:09:59;29")
        #expect(Timecode(frames: 17_982).string(rate: .fps29_97, dropFrame: true) == "00:10:00;00")
        #expect(Timecode(frames: 107_892).string(rate: .fps29_97, dropFrame: true) == "01:00:00;00")
    }

    @Test("59.94 drop frame skips four labels per minute")
    func dropFrame59_94() {
        #expect(Timecode(frames: 3_599).string(rate: .fps59_94, dropFrame: true) == "00:00:59;59")
        #expect(Timecode(frames: 3_600).string(rate: .fps59_94, dropFrame: true) == "00:01:00;04")
        #expect(Timecode(frames: 7_195).string(rate: .fps59_94, dropFrame: true) == "00:01:59;59")
        #expect(Timecode(frames: 7_196).string(rate: .fps59_94, dropFrame: true) == "00:02:00;04")
        #expect(Timecode(frames: 35_963).string(rate: .fps59_94, dropFrame: true) == "00:09:59;59")
        #expect(Timecode(frames: 35_964).string(rate: .fps59_94, dropFrame: true) == "00:10:00;00")
        #expect(Timecode(frames: 215_784).string(rate: .fps59_94, dropFrame: true) == "01:00:00;00")
    }

    @Test("Drop frame parsing rejects skipped labels")
    func rejectsSkippedDropLabels() {
        #expect(Timecode(string: "00:01:00;00", rate: .fps29_97) == nil)
        #expect(Timecode(string: "00:01:00;01", rate: .fps29_97) == nil)
        #expect(Timecode(string: "00:01:00;02", rate: .fps29_97)?.frames == 1_800)
        #expect(Timecode(string: "00:10:00;00", rate: .fps29_97)?.frames == 17_982)

        #expect(Timecode(string: "00:01:00;03", rate: .fps59_94) == nil)
        #expect(Timecode(string: "00:01:00;04", rate: .fps59_94)?.frames == 3_600)
        #expect(Timecode(string: "00:10:00;00", rate: .fps59_94)?.frames == 35_964)
    }

    @Test("Drop frame is ignored for rates that cannot use it")
    func dropFrameIsOnlyForNTSC() {
        #expect(!FrameRate.fps25.supportsDropFrame)
        #expect(!FrameRate.fps30.supportsDropFrame)
        #expect(!FrameRate.fps23_976.supportsDropFrame)
        #expect(FrameRate.fps29_97.supportsDropFrame)
        #expect(FrameRate.fps59_94.supportsDropFrame)
        #expect(Timecode(frames: 25).string(rate: .fps25, dropFrame: true) == "00:00:01:00")
        #expect(Timecode.oneHour(rate: .fps25, dropFrame: true).frames == 90_000)
    }

    @Test("Converts seconds to frames and back")
    func secondsConversion() {
        #expect(Timecode(seconds: 10, rate: .fps25).frames == 250)
        #expect(Timecode(seconds: 10, rate: .fps29_97).frames == 300)
        #expect(Timecode(seconds: 10, rate: .fps23_976).frames == 240)
        #expect(Timecode(seconds: 10, rate: .fps59_94).frames == 599)
        #expect(Timecode(seconds: 0.04, rate: .fps25).frames == 1)
        #expect(abs(Timecode(frames: 300).seconds(rate: .fps29_97) - 10.01) < 0.0001)
    }

    @Test("One hour of timecode is 01:00:00:00 at every rate")
    func oneHour() {
        for rate in FrameRate.all {
            for drop in [false, true] where !drop || rate.supportsDropFrame {
                let tc = Timecode.oneHour(rate: rate, dropFrame: drop)
                #expect(tc.string(rate: rate, dropFrame: drop) == (drop ? "01:00:00;00" : "01:00:00:00"))
            }
        }
    }

    @Test("Advances across second and minute boundaries")
    func advance() {
        #expect(
            Timecode(string: "00:00:59:24", rate: .fps25)?.advanced(by: 1).string(rate: .fps25, dropFrame: false)
                == "00:01:00:00"
        )
        #expect(
            Timecode(string: "00:00:59;29", rate: .fps29_97)?.advanced(by: 1).string(rate: .fps29_97, dropFrame: true)
                == "00:01:00;02"
        )
        #expect(
            Timecode(string: "00:09:59;29", rate: .fps29_97)?.advanced(by: 1).string(rate: .fps29_97, dropFrame: true)
                == "00:10:00;00"
        )
    }

    @Test("Parsing is the inverse of formatting for every rate")
    func roundTripProperty() {
        for rate in FrameRate.all {
            for drop in [false, true] where !drop || rate.supportsDropFrame {
                for frame in stride(from: 0, through: 30_000, by: 1) {
                    let text = Timecode(frames: frame).string(rate: rate, dropFrame: drop)
                    let parsed = Timecode(string: text, rate: rate)
                    #expect(parsed?.frames == frame, "\(rate) drop=\(drop) frame=\(frame) text=\(text)")
                }
                for frame in [90_000, 107_892, 215_784] {
                    let text = Timecode(frames: frame).string(rate: rate, dropFrame: drop)
                    let parsed = Timecode(string: text, rate: rate)
                    #expect(parsed?.frames == frame, "\(rate) drop=\(drop) frame=\(frame) text=\(text)")
                }
            }
        }
    }

    @Test("Duration clock formats m:ss and h:mm:ss")
    func durationClock() {
        #expect(DurationFormat.clock(seconds: 0) == "0:00")
        #expect(DurationFormat.clock(seconds: 9) == "0:09")
        #expect(DurationFormat.clock(seconds: 65) == "1:05")
        #expect(DurationFormat.clock(seconds: 3_723) == "1:02:03")
        #expect(DurationFormat.clock(frames: 250, rate: .fps25) == "0:10")
        #expect(DurationFormat.clock(frames: 299, rate: .fps29_97) == "0:10")
        #expect(DurationFormat.clock(frames: 300, rate: .fps29_97) == "0:10")
        // 35964 frames at 29.97 is 1199.9994 s and must print 20:00.
        #expect(DurationFormat.clock(frames: 35_964, rate: .fps29_97) == "20:00")
        #expect(DurationFormat.clock(seconds: 10, rate: .fps59_94) == "0:10")
        #expect(DurationFormat.clock(seconds: 9.6, rate: .fps25) == "0:10")
    }

    @Test("Non-finite seconds do not trap")
    func nonFiniteSeconds() {
        #expect(Timecode(seconds: .infinity, rate: .fps25).frames == 0)
        #expect(Timecode(seconds: -.infinity, rate: .fps25).frames == 0)
        #expect(Timecode(seconds: .nan, rate: .fps25).frames == 0)
        #expect(Timecode(seconds: -3, rate: .fps25).frames == 0)
    }
}
