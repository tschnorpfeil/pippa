import Foundation
import PippaCore

@MainActor func runTopicBoundaryChecks() {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    let photos = [ConversationMessage(role: .user, text: "Kannst du mir das neuste Bild aus meiner Fotos-App zeigen?", timestamp: start),
                  ConversationMessage(role: .assistant, text: "Hier ist dein neustes Foto.", timestamp: start.addingTimeInterval(20))]
    let answered = start.addingTimeInterval(20)
    func starts(_ text: String, after seconds: TimeInterval, _ messages: [ConversationMessage] = photos) -> Bool {
        TopicBoundary.startsNewTopic(text, messages: messages, now: answered.addingTimeInterval(seconds))
    }

    check("Topic: a greeting after a short pause starts a new topic, right after the answer it does not") {
        starts("Hey Pippa, was geht ab?", after: 180) && starts("Guten Morgen!", after: 600) && starts("Hi", after: 121)
            && !starts("Hey Pippa, was geht ab?", after: 60)
    }
    check("Topic: after a long pause a message of its own starts a new topic") {
        starts("Wie wird das Wetter morgen in Köln?", after: 1800) && starts("What's the weather tomorrow?", after: 3600)
            && !starts("Wie wird das Wetter morgen in Köln?", after: 1799)
    }
    check("Topic: what refers back never starts a topic, also after a pause or with a greeting") {
        ["Und das davor?", "Danke!", "Das ist toll, kannst du es größer machen?", "Hey Pippa, und das Foto von vorhin?",
         "Kannst du das noch mal kürzer schreiben?", "Mach es bitte kürzer und einfacher", "What about the second one?", "ok"]
            .allSatisfy { !starts($0, after: 7200) }
    }
    check("Topic: short replies after a pause stay in the topic") {
        !starts("Wetter morgen?", after: 7200) && !starts("Ja", after: 7200)
    }
    check("Topic: only once the current topic has a question and an answer") {
        !starts("Hey Pippa, was geht ab?", after: 600, [photos[0]]) && !starts("Hallo", after: 600, [])
            && !starts("Hallo", after: 600, [ConversationMessage(role: .system, text: "Added: Brief.pdf", timestamp: start)])
    }
    check("Topic: the pause counts from the latest topic, and a fresh topic needs its own answer first") {
        let greeted = ConversationMessage(role: .user, text: "Hey Pippa", timestamp: answered.addingTimeInterval(600), topicStart: true)
        let withStart = photos + [greeted]
        let answer = ConversationMessage(role: .assistant, text: "Hey!", timestamp: answered.addingTimeInterval(610))
        return !TopicBoundary.startsNewTopic("Hallo nochmal", messages: withStart, now: answered.addingTimeInterval(900))
            && !TopicBoundary.startsNewTopic("Moin", messages: withStart, now: answered.addingTimeInterval(900))
            && TopicBoundary.startsNewTopic("Moin", messages: withStart + [answer], now: answered.addingTimeInterval(900))
            && TopicBoundary.latestStart(withStart + [answer]) == 2
            && TopicBoundary.currentTopic(withStart + [answer]).count == 2
    }
    check("Topic: a new topic gives Pi a new session, keeps the history and survives reopening") {
        let store = try ConversationStore(directory: dir("topic-boundary"))
        let topic = try store.create()
        _ = try store.append(photos[0], to: topic.id)
        _ = try store.append(photos[1], to: topic.id)
        let first = try store.startTopic(in: topic.id)
        guard let revision = first.modelSessionRevision, first.retiredModelSessionRevisions == nil else { return false }
        _ = try store.append(ConversationMessage(role: .user, text: "Hey Pippa", topicStart: true), to: topic.id)
        let second = try store.startTopic(in: topic.id)
        let loaded = try ConversationStore(directory: store.fileURL.deletingLastPathComponent()).load(topic.id)
        return second.modelSessionRevision != revision && loaded.retiredModelSessionRevisions == [revision]
            && loaded.messages.count == 3 && loaded.messages[2].topicStart == true && loaded.messages[0].topicStart == nil
    }
}
