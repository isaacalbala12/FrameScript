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

    @Test("JSON-RPC ids accept strings and integers only")
    func jsonRPCIDs() {
        #expect(JSONRPCID(jsonValue: .int(7)) == .int(7))
        #expect(JSONRPCID(jsonValue: .string("abc")) == .string("abc"))
        #expect(JSONRPCID(jsonValue: .null) == nil)
        #expect(JSONRPCID(jsonValue: .double(1.5)) == nil)
        #expect(JSONRPCID(jsonValue: .bool(true)) == nil)
        #expect(JSONRPCID(jsonValue: .array([])) == nil)
    }

    @Test("line framer splits arbitrary chunks")
    func framerSplitsChunks() {
        var framer = MCPLineFramer()

        #expect(framer.append(Data("one\ntw".utf8)) == [Data("one".utf8)])
        #expect(framer.append(Data("o\nthree\r".utf8)) == [Data("two".utf8)])
        #expect(framer.append(Data("\n".utf8)) == [Data("three".utf8)])
        #expect(framer.flush() == nil)
    }

    @Test("line framer flushes an unterminated final line")
    func framerFlushesTail() {
        var framer = MCPLineFramer()
        #expect(framer.append(Data("partial".utf8)).isEmpty)
        #expect(framer.flush() == Data("partial".utf8))
        #expect(framer.flush() == nil)
    }

    @Test("line framer preserves empty lines")
    func framerPreservesEmptyLines() {
        var framer = MCPLineFramer()
        #expect(framer.append(Data("\n\n".utf8)) == [Data(), Data()])
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
    }
}
