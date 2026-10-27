import Foundation

@main
struct TranscriptionTimingTests {
    static func main() throws {
        let plain = try JSONDecoder().decode(ElevenLabsRealtimeEvent.self, from: Data(
            #"{"message_type":"committed_transcript","text":"Make this red."}"#.utf8))
        precondition(plain.completesCommit(includingTimings: false))
        precondition(!plain.completesCommit(includingTimings: true))
        let timed = try JSONDecoder().decode(ElevenLabsRealtimeEvent.self, from: Data(#"""
        {"message_type":"committed_transcript_with_timestamps","text":"Make this red.","words":[
          {"text":"Make","start":0.1,"end":0.4,"type":"word"},
          {"text":" ","start":0.4,"end":0.5,"type":"spacing"},
          {"text":"this","start":0.5,"end":0.7},
          {"text":"red.","start":0.8,"end":1.1},
          {"text":"missing timing"},{"text":"bad timing","start":-1,"end":0} ]}
        """#.utf8))
        precondition(timed.completesCommit(includingTimings: true))
        precondition(timed.spans.map(\.text) == ["Make", "this", "red."])
        precondition(timed.spans[2].shifted(by: 100).end == 101.1)
        precondition(!TranscriptSpan(text: "invalid", start: .nan, end: 1).isValid)
        print("Delayed committed timestamps, optional words and invalid timing checks passed")
    }
}
