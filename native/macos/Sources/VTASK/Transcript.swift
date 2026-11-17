import Foundation

struct Transcript: Decodable {
    struct Segment: Decodable, Identifiable, Hashable {
        struct VoiceSuggestion: Decodable, Hashable {
            let status: String
            let personName: String?
            let personId: Int?
        }

        let id: Int
        let text: String
        let personName: String?
        let speakerId: String?
        let voiceSuggestion: VoiceSuggestion?

        var resolvedSpeakerID: Int? {
            personId ?? (voiceSuggestion?.status == "candidate" ? voiceSuggestion?.personId : nil)
        }

        var speakerLabel: String {
            if let personName { return personName }
            if voiceSuggestion?.status == "candidate", let name = voiceSuggestion?.personName {
                return name
            }
            return "Говорящий не определён"
        }
        let personId: Int?
        let startMs: Int
        let endMs: Int
    }

    struct VoiceMatch: Decodable, Identifiable {
        let speakerId: String
        let status: String
        let personId: Int?
        let personName: String?
        let similarity: Double?
        var id: String { speakerId }
    }

    struct SpeakerAssignment: Decodable { let speakerId: String? }
    struct SpeakerTurn: Decodable { let speakerId: String }

    let voiceMatches: [VoiceMatch]?
    let speakerAssignments: [SpeakerAssignment]?
    let speakerTurns: [SpeakerTurn]?
    let modelRunId: Int
    let segments: [Segment]
}
