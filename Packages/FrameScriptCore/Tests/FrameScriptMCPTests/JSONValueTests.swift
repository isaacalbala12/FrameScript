import Foundation
import Testing
@testable import FrameScriptMCP

@Suite("JSON value and framing")
struct JSONValueTests {
    @Test("round-trips every JSON case")
    func roundTripsAllCases() throws {
        let value = JSONValue.object([
            "null": .null,
            "bool": .bool(true),
            "int": .int(42),
            "double": .double(2.5),
            "string": .string("hello"),
            "array": .array([.int(1), .string("two")]),
            "nested": .object(["key": .string("value")])
        ])

        let data = try MCPJSON.encode(value)
        let decoded = try MCPJSON.decode(data)

        #expect(decoded == value)
        #expect(decoded["int"]?.intValue == 42)
        #expect(decoded["double"]?.doubleValue == 2.5)
        #expect(decoded["string"]?.stringValue == "hello")
        #expect(decoded["array"]?.arrayValue?.count == 2)
        #expect(decoded["nested"]?["key"]?.stringValue == "value")
    }

    @Test("distinguishes integers and doubles")
    func distinguishesNumbers() throws {
        let decoded = try MCPJSON.decode(Data(#"{"a":42,"b":42.5,"c":true}"#.utf8))
        #expect(decoded["a"]?.intValue == 42)
        #expect(decoded["b"]?.intValue == nil)
        #expect(decoded["b"]?.doubleValue == 42.5)
        #expect(decoded["c"]?.boolValue == true)
    }

    @Test("encodes deterministically with sorted keys")
    func deterministicEncoding() throws {
        let value = JSONValue.object([
            "z": .int(1),
            "a": .int(2),
            "m": .int(3)
        ])
        let first = try MCPJSON.encode(value)
        let second = try MCPJSON.encode(value)
        #expect(first == second)

        let text = try #require(String(data: first, encoding: .utf8))
        #expect(text == #"{"a":2,"m":3,"z":1}"#)
    }

    @Test("a line-encoded message has exactly one trailing newline")
    func encodedLineIsSingleLine() throws {
        let line = try MCPJSON.encodeLine(.object([
            "text": .string("line one\nline two"),
            "value": .int(1)
        ]))

        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        #expect(line.dropLast().contains(0x0D) == false)

        let decoded = try MCPJSON.decodeLine(line.dropLast())
        #expect(decoded["text"]?.stringValue == "line one\nline two")
    }

    @Test("refuses to encode non-finite numbers")
    func refusesNonFiniteNumbers() {
        do {
            _ = try MCPJSON.encode(.object(["n": .double(.infinity)]))
            Issue.record("expected MCPJSONError.nonFiniteNumber")
        } catch let error as MCPJSONError {
            #expect(error == .nonFiniteNumber(path: "n"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        let nested = JSONValue.object(["a": .array([.double(.nan)])])
        #expect(nested.nonFiniteNumberPath == "a[0]")
        #expect(JSONValue.double(.infinity).nonFiniteNumberPath == "")
    }

    @Test("JSON-RPC ids accept strings and integral numbers only")
    func jsonRPCIDs() {
        #expect(JSONRPCID(jsonValue: .int(7)) == .int(7))
        #expect(JSONRPCID(jsonValue: .string("abc")) == .string("abc"))
        #expect(JSONRPCID(jsonValue: .double(7.0)) == .int(7))
        #expect(JSONRPCID(jsonValue: .null) == nil)
        #expect(JSONRPCID(jsonValue: .double(1.5)) == nil)
        #expect(JSONRPCID(jsonValue: .double(.infinity)) == nil)
        #expect(JSONRPCID(jsonValue: .bool(true)) == nil)
        #expect(JSONRPCID(jsonValue: .array([])) == nil)
    }

    @Test("line framer splits arbitrary chunks")
    func framerSplitsChunks() throws {
        var framer = MCPLineFramer()

        #expect(try framer.append(Data("one\ntw".utf8)) == [Data("one".utf8)])
        #expect(try framer.append(Data("o\nthree\r".utf8)) == [Data("two".utf8)])
        #expect(try framer.append(Data("\n".utf8)) == [Data("three".utf8)])
        #expect(try framer.flush() == nil)
    }

    @Test("line framer flushes an unterminated final line")
    func framerFlushesTail() throws {
        var framer = MCPLineFramer()
        #expect(try framer.append(Data("partial".utf8)).isEmpty)
        #expect(try framer.flush() == Data("partial".utf8))
        #expect(try framer.flush() == nil)
    }

    @Test("line framer preserves empty lines")
    func framerPreservesEmptyLines() throws {
        var framer = MCPLineFramer()
        #expect(try framer.append(Data("\n\n".utf8)) == [Data(), Data()])
    }

    @Test("line framer scans each byte only once")
    func framerScansLinearly() throws {
        var framer = MCPLineFramer()
        let chunkSize = 64 * 1024
        let total = 4 * 1024 * 1024
        let chunk = Data(repeating: 0x61, count: chunkSize)

        for _ in 0..<(total / chunkSize) {
            #expect(try framer.append(chunk).isEmpty)
        }

        #expect(framer.scannedByteCount == total)
        #expect(framer.hasBufferedBytes)
        #expect(try framer.flush()?.count == total)
    }

    @Test("line framer enforces a maximum message size")
    func framerEnforcesMaximumSize() {
        var framer = MCPLineFramer(maximumMessageSize: 1024)
        do {
            _ = try framer.append(Data(repeating: 0x61, count: 1025))
            Issue.record("expected MCPFramingError.messageTooLarge")
        } catch let error as MCPFramingError {
            #expect(error == .messageTooLarge(limit: 1024))
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        var completeLine = MCPLineFramer(maximumMessageSize: 8)
        do {
            _ = try completeLine.append(Data("123456789\n".utf8))
            Issue.record("expected a complete over-limit line to be rejected")
        } catch let error as MCPFramingError {
            #expect(error == .messageTooLarge(limit: 8))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("in-memory channel rejects embedded newlines")
    func inMemoryChannelRejectsEmbeddedNewlines() async {
        let channel = MCPInMemoryChannel()
        do {
            try await channel.send(Data("a\nb".utf8))
            Issue.record("expected MCPTransportError.embeddedNewline")
        } catch let error as MCPTransportError {
            #expect(error == .embeddedNewline)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("parses request, notification and response envelopes")
    func parsesEnvelopes() throws {
        let request = JSONRPCIncoming.parse(try MCPJSON.encode(
            RPC.request(id: 3, method: "ping")
        ))
        guard case .request(let parsedRequest) = request else {
            Issue.record("expected a request, got \(request)")
            return
        }
        #expect(parsedRequest.id == .int(3))
        #expect(parsedRequest.method == "ping")

        let notification = JSONRPCIncoming.parse(try MCPJSON.encode(
            RPC.notification("notifications/initialized")
        ))
        guard case .notification(let parsedNotification) = notification else {
            Issue.record("expected a notification, got \(notification)")
            return
        }
        #expect(parsedNotification.method == "notifications/initialized")

        let response = JSONRPCIncoming.parse(Data(#"{"jsonrpc":"2.0","id":9,"result":{}}"#.utf8))
        guard case .response(let id) = response else {
            Issue.record("expected a response, got \(response)")
            return
        }
        #expect(id == .int(9))
    }

    @Test("rejects batching, null ids and malformed JSON")
    func rejectsInvalidEnvelopes() {
        let batch = JSONRPCIncoming.parse(Data(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#.utf8))
        guard case .invalid(_, let batchError) = batch else {
            Issue.record("expected invalid batch")
            return
        }
        #expect(batchError.code == JSONRPCErrorCode.invalidRequest.rawValue)

        let nullID = JSONRPCIncoming.parse(Data(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#.utf8))
        guard case .invalid(let id, let nullIDError) = nullID else {
            Issue.record("expected invalid null id")
            return
        }
        #expect(id == nil)
        #expect(nullIDError.code == JSONRPCErrorCode.invalidRequest.rawValue)

        let malformed = JSONRPCIncoming.parse(Data("{not json".utf8))
        guard case .invalid(let malformedID, let parseError) = malformed else {
            Issue.record("expected parse error")
            return
        }
        #expect(malformedID == nil)
        #expect(parseError.code == JSONRPCErrorCode.parseError.rawValue)
        #expect(parseError.data == nil)
    }
}
