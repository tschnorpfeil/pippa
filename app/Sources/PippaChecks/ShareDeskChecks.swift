import Foundation
import PippaCore

// The review's lifecycle (issue #193, P5): cancel, closing the sheet, switching conversations and failed sends keep the
// person's edits in the conversation they belong to; a draft typed meanwhile is never overwritten; nothing is resent by
// itself. Synthetic data only.

func runShareDeskChecks() {
    let openai = ShareDestination(PiModelSelection(providerID: "openai", modelID: "gpt-fixture", providerName: "OpenAI"))
    let anthropic = ShareDestination(PiModelSelection(providerID: "anthropic", modelID: "claude-fixture", providerName: "Anthropic"))
    let rules = SourceSharing()
    let lease = URL(fileURLWithPath: "/Users/fixture/Documents/Lease.pdf")
    let scan = URL(fileURLWithPath: "/Users/fixture/Pictures/Scan.jpg")
    let mail = SharePiece(sources: [.mail], title: "Email “Rent”", text: "MAIL-MARKER-7 pay by Friday")
    let doc = SharePiece(sources: [.documents], title: "Lease.pdf", text: "DOC-MARKER-8 notice period")
    let typed = ShareComposer(text: "Is the notice right?", files: [lease])

    /// A review open in conversation "a", with the lease read and the person's edits made.
    func edited() -> ShareDesk {
        var desk = ShareDesk()
        let unread = desk.open(in: "a", destination: openai, handoff: false, composer: typed, fresh: [], rules: rules)
        guard unread == [lease], let id = desk.open?.id else { return desk }
        desk.add([doc], files: [lease], to: id, rules: rules)
        desk.update { plan in
            plan.question = "Is the notice period right? EDITED-Q"
            plan.pieces[0].text = "DOC-MARKER-8 EDITED-EXCERPT"
        }
        return desk
    }

    check("Review lifecycle: Cancel keeps every edit; the edited words go back into the unchanged composer; reopening resumes them") {
        var desk = edited()
        let id = desk.open?.id
        let back = desk.cancel(current: "a", composer: typed)
        let unread = desk.open(in: "a", destination: openai, handoff: false, composer: back ?? typed, fresh: [], rules: rules)
        guard let review = desk.open else { return false }
        return back?.text == "Is the notice period right? EDITED-Q" && back?.files == [lease] && unread.isEmpty
            && review.id == id && review.plan.question == "Is the notice period right? EDITED-Q"
            && review.plan.pieces.map(\.text) == ["DOC-MARKER-8 EDITED-EXCERPT"] && desk.parked.isEmpty && !review.loading
    }
    check("Review lifecycle: a removed file takes its part along, a new one is read; parts are offered under today's rules") {
        var desk = edited()
        guard let id = desk.open?.id else { return false }
        desk.add([mail], to: id, rules: rules)
        _ = desk.cancel(current: "a", composer: typed)
        var stricter = rules; stricter.mail = .localOnly
        let unread = desk.open(in: "a", destination: openai, handoff: false, composer: ShareComposer(text: typed.text, files: [scan]),
                               fresh: [], rules: stricter)
        guard let review = desk.open else { return false }
        return unread == [scan] && review.loading && review.plan.pieces.isEmpty && review.plan.withheld.map(\.title) == [mail.title]
            && review.plan.withheld.allSatisfy { $0.text.isEmpty } && review.files == [scan]
    }
    check("Review lifecycle: switching conversations parks the review with its own; Send there never lands in the other") {
        var desk = edited()
        desk.select("b")
        let elsewhere = desk.approve(current: "b", destination: openai, composer: ShareComposer(), rules: rules)
        let parkedHere = desk.parked(in: "a", handoff: false)
        var reopened = desk
        reopened.open(in: "a", destination: openai, handoff: false, composer: ShareComposer(), fresh: [], rules: rules, explicit: true)
        // A review that is still open while the shown conversation changed underneath (Island) is parked, not sent.
        var raced = edited()
        let racedOutcome = raced.approve(current: "b", destination: openai, composer: typed, rules: rules)
        guard case .send(let approval, let sent, let clear) = reopened.approve(current: "a", destination: openai, composer: typed, rules: rules)
        else { return false }
        return desk.open == nil && elsewhere == .nothing && parkedHere?.conversation == "a"
            && racedOutcome == .parked && raced.open == nil && raced.parked(in: "a", handoff: false) != nil
            && sent.conversation == "a" && clear && approval.message.contains("EDITED-EXCERPT") && approval.question.hasSuffix("EDITED-Q")
    }
    check("Review lifecycle: Send leaves a draft typed meanwhile alone; a changed recipient keeps the review open, nothing sent") {
        var desk = edited()
        guard case .send(_, _, let clear) = desk.approve(current: "a", destination: openai, composer: ShareComposer(text: "NEW-DRAFT"), rules: rules)
        else { return false }
        var changed = edited()
        let outcome = changed.approve(current: "a", destination: anthropic, composer: typed, rules: rules)
        var gone = edited()
        let local = gone.approve(current: "a", destination: nil, composer: typed, rules: rules)
        return !clear && outcome == .destinationChanged && changed.open != nil && local == .destinationChanged && gone.open != nil
    }
    check("Review lifecycle: a failed send is parked with its edits and the reason; never resent; words back only into an empty composer") {
        var desk = edited()
        guard case .send(_, let sent, _) = desk.approve(current: "a", destination: openai, composer: typed, rules: rules) else { return false }
        var busy = desk
        let intoBusy = busy.failed(sent, problem: "Provider error 500", current: "a", composer: ShareComposer(text: "TYPED-DURING-ANSWER"))
        var elsewhere = desk
        let intoOther = elsewhere.failed(sent, problem: "Provider error 500", current: "b", composer: ShareComposer())
        let intoEmpty = desk.failed(sent, problem: "Provider error 500", current: "a", composer: ShareComposer())
        let parked = busy.parked(in: "a", handoff: false)
        let resent = desk.approve(current: "a", destination: openai, composer: intoEmpty ?? ShareComposer(), rules: rules)
        return intoBusy == nil && intoOther == nil && intoEmpty == typed && parked?.problem == "Provider error 500"
            && parked?.plan.pieces.first?.text == "DOC-MARKER-8 EDITED-EXCERPT" && busy.open == nil
            && elsewhere.parked(in: "a", handoff: false) != nil && elsewhere.parked(in: "b", handoff: false) == nil
            && resent == .nothing && desk.open == nil
    }
    check("Review lifecycle: a read that finishes after Cancel joins the parked review, never another conversation's") {
        var desk = ShareDesk()
        desk.open(in: "a", destination: openai, handoff: true, composer: ShareComposer(text: "Q"), fresh: [], rules: rules)
        desk.reading()
        guard let id = desk.open?.id else { return false }
        _ = desk.cancel(current: "a", composer: ShareComposer(text: "Q"))
        desk.open(in: "b", destination: openai, handoff: true, composer: ShareComposer(text: "Other"), fresh: [], rules: rules)
        desk.add([mail], to: id, rules: rules)
        let parked = desk.parked(in: "a", handoff: true)
        return desk.open?.plan.pieces.isEmpty == true && parked?.plan.pieces.map(\.title) == [mail.title] && parked?.loading == false
    }
    check("Review lifecycle: a new question typed after Cancel replaces the old words; a single question and the online route park apart") {
        var desk = edited()
        _ = desk.cancel(current: "a", composer: typed)
        desk.open(in: "a", destination: openai, handoff: true, composer: ShareComposer(text: "Handoff Q"), fresh: [], rules: rules)
        _ = desk.cancel(current: "a", composer: ShareComposer(text: "Handoff Q"))
        desk.open(in: "a", destination: anthropic, handoff: false, composer: ShareComposer(text: "Something else", files: [lease]),
                  fresh: [], rules: rules)
        let review = desk.open
        desk.forget("a")
        return review?.plan.question == "Something else" && review?.plan.destination == anthropic
            && review?.plan.pieces.first?.text == "DOC-MARKER-8 EDITED-EXCERPT"
            && desk.open == nil && desk.parked.isEmpty
    }
}
