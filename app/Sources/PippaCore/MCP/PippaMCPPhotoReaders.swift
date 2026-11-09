import Foundation

extension PippaMCPTools {
    // MARK: Photos

    /// Photos' own search, then the card. The model gets dates and the count, never ids or file names; the person sees
    /// the pictures (`PhotoCard` in the read note). Previews need PhotoKit's permission, asked once right after the
    /// first search that found something (one sentence from Pippa covers both).
    func photosSearch(_ input: ToolInput) async -> PippaMCPToolResult {
        let asked = Self.photoQuery(input.query ?? "")
        let limit = input.limit ?? 12
        guard (1...PhotoCard.maxItems).contains(limit) else { return invalid("limit must be 1 to \(PhotoCard.maxItems).") }
        if let days = input.days, !(1...366).contains(days) { return invalid("days must be 1 to 366.") }
        // "das neueste Bild", "Fotos von gestern": no content search, the newest by date (PhotoKit).
        if asked.isEmpty { return await recentPhotos(days: input.days, limit: limit) }
        if let wish = Self.newestWish(asked) { return await recentPhotos(days: input.days ?? wish.days, limit: limit) }
        guard input.days == nil else { return invalid("days only works without query. Search with query alone.") }
        guard (2...60).contains(asked.count) else { return invalid("query must be one word, 2 to 60 characters.") }
        var access = await host.hostData.photosAccess(ask: false)
        var explained = false
        if access == .notDetermined && host.askForAccess, await mayAsk(.photos) {
            explained = true
            access = await host.hostData.photosAccess(ask: true)
        }
        switch access {
        case .granted: break
        case .notDetermined: return blocked("needs_access", Self.notYet(app: PhotosLibrary.appName))
        case .denied: return blocked("denied", Self.deniedAutomation(PhotosLibrary.appName), repair: .automation)
        case .unavailable: return blocked("unavailable", L("Open %@ first. Then ask again.", table: "MCP", PhotosLibrary.appName))
        }
        do {
            var query = asked
            var fetch = try await host.hostData.searchPhotos(query, limit: limit)
            // Nothing for several words: once more with the one word that most likely names the thing.
            if fetch.total == 0, let word = Self.photoWord(asked), word != asked {
                query = word
                fetch = try await host.hostData.searchPhotos(word, limit: limit)
            }
            // Automation may already be allowed while PhotoKit has never been asked. Explain once for this call,
            // and ask only when there are pictures to preview. A known denial always needs Settings instead.
            var library = await host.hostData.photoLibraryAccess(ask: false)
            var askForPreviews = false
            if !fetch.items.isEmpty, library == .notDetermined, host.askForAccess {
                askForPreviews = explained ? true : await mayAsk(.photos, explanation:
                    L("To show these pictures here, I need access to your photo library on this Mac. I don’t change anything.", table: "MCP"))
            }
            let previews = await host.hostData.photoPreviewAccess(ask: askForPreviews)
            if askForPreviews { library = await host.hostData.photoLibraryAccess(ask: false) }
            let cal = host.calendar
            let items = fetch.items.map { hit in
                PhotoCard.Item(id: hit.id, date: hit.date, dateLabel: hit.date.map { Self.dateLabel($0, time: false, calendar: cal) } ?? "",
                               label: hit.title.isEmpty ? hit.filename : hit.title)
            }
            let card = PhotoCard(query: query, items: items, total: fetch.total, previews: previews,
                                 footer: L("Photos on this Mac · %lld found", table: "MCP", fetch.total),
                                 truncatedNote: fetch.total > items.count
                                    ? L("Showing %lld of %lld. Search for “%@” in Photos to see all of them.", table: "MCP", items.count, fetch.total, query) : nil)
            let photos = fetch.items.map { hit -> [String: Any] in
                var value: [String: Any] = [:]
                if let date = hit.date { value["date"] = Self.dateLabel(date, time: false, calendar: cal) }
                if !hit.title.isEmpty { value["title"] = hit.title }
                return value
            }
            var result = Self.bounded(source: "Photos on this Mac (search by content, place or text)",
                                      data: ["query": query, "photos": photos, "shown": photos.count, "total": fetch.total,
                                             "truncated": fetch.total > photos.count, "previews_available": previews],
                                      next: (previews ? "The person sees these photos as pictures under your answer. "
                                             : "Photo previews are unavailable. Search results can show names and dates; do not claim the pictures are displayed. ")
                                        + "Say in one sentence how many were found and from when; do not list them. If photos is empty, Photos found nothing for this word: suggest one other word.")
            // Nothing found: no card, the answer says so (as for mail_search).
            if !items.isEmpty { result.card = .photos(card) }
            if !items.isEmpty, library == .denied { result.permissionRepair = .photos }
            return result
        } catch PippaError.accessDenied {
            return blocked("denied", Self.deniedAutomation(PhotosLibrary.appName), repair: .automation)
        } catch PippaError.appNotOpen {
            return blocked("unavailable", L("Open %@ first. Then ask again.", table: "MCP", PhotosLibrary.appName))
        } catch {
            return blocked("failed", L("Pippa couldn’t read %@ just now. Please try again.", table: "MCP", PhotosLibrary.appName))
        }
    }

    /// The newest photos, with `days` only those of the last days (1 = today). Needs only PhotoKit's permission.
    private func recentPhotos(days: Int?, limit: Int) async -> PippaMCPToolResult {
        var access = await host.hostData.photoLibraryAccess(ask: false)
        if access == .notDetermined && host.askForAccess, await mayAsk(.photos) {
            access = await host.hostData.photoLibraryAccess(ask: true)
        }
        switch access {
        case .granted: break
        case .denied: return blocked("denied", Self.deniedPhotoLibrary, repair: .photos)
        default: return blocked("needs_access", Self.notYet(app: PhotosLibrary.appName))
        }
        let cal = host.calendar
        let since = days.flatMap { cal.date(byAdding: .day, value: 1 - $0, to: cal.startOfDay(for: host.now())) }
        do {
            let fetch = try await host.hostData.recentPhotos(since: since, limit: limit)
            let items = fetch.items.map { hit in
                PhotoCard.Item(id: hit.id, date: hit.date, dateLabel: hit.date.map { Self.dateLabel($0, time: false, calendar: cal) } ?? "",
                               label: hit.title.isEmpty ? hit.filename : hit.title)
            }
            // Without days the total is the whole library: neither a count nor "shown of" means anything to the person.
            let card = PhotoCard(query: "", items: items, total: fetch.total, previews: true, footer: L("Photos on this Mac", table: "MCP"),
                                 truncatedNote: since != nil && fetch.total > items.count
                                    ? L("Showing %lld of %lld. Open Photos to see all of them.", table: "MCP", items.count, fetch.total) : nil)
            var data: [String: Any] = ["photos": items.map { $0.dateLabel.isEmpty ? [:] : ["date": $0.dateLabel] }, "shown": items.count]
            if let days { data["days"] = days; data["total"] = fetch.total; data["truncated"] = fetch.total > items.count }
            var result = Self.bounded(source: "Photos on this Mac (newest first)", data: data,
                                      next: "The person sees these photos as pictures under your answer. Say in one sentence what is shown (how many, from when); do not list them. If photos is empty, there are no photos for this period.")
            if !items.isEmpty { result.card = .photos(card) }
            return result
        } catch PippaError.accessDenied {
            return blocked("denied", Self.deniedPhotoLibrary, repair: .photos)
        } catch {
            return blocked("failed", L("Pippa couldn’t read %@ just now. Please try again.", table: "MCP", PhotosLibrary.appName))
        }
    }

    static var deniedPhotoLibrary: String {
        L("Pippa may not see your photos. To change that, open System Settings → Privacy & Security → Photos and turn on Pippa.", table: "MCP")
    }

    /// The search text without quotes and punctuation, words separated by one space.
    static func photoQuery(_ raw: String) -> String {
        raw.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.joined(separator: " ")
    }

    /// Photos searches one word best: "Fotos von meinem Fahrrad" should arrive as "Fahrrad", but small models sometimes
    /// send the whole wish. Words that only say "picture" and short filler words go; the last word left stays (in German
    /// and English phrases usually the thing itself: "Bilder aus Knokke", "photos of my bike"). `nil` for one word.
    static func photoWord(_ query: String) -> String? {
        let words = query.split(separator: " ").map(String.init)
        guard words.count > 1 else { return nil }
        let kept = words.filter { $0.count > 3 && !photoFiller.contains($0.lowercased()) }
        return kept.last ?? words.last
    }

    /// Words that only say "picture" or "my".
    static let photoFiller: Set<String> = ["foto", "fotos", "bild", "bilder", "photo", "photos", "picture", "pictures", "image", "images",
                                           "pic", "pics", "meine", "meiner", "meinen", "meinem", "unsere", "unserer", "unseren", "unserem",
                                           "alle", "aus", "von", "mit", "my", "the", "of", "from"]

    /// Small models sometimes put "the newest" into query ("neuestes Bild", "Fotos von gestern") instead of leaving it out.
    /// `nil`: a real search word is in there. Otherwise a wish for the newest, with the days it names (today 1, yesterday 2).
    struct NewestWish { var days: Int? }

    static func newestWish(_ query: String) -> NewestWish? {
        let newest: Set<String> = ["neueste", "neuestes", "neuesten", "neuster", "neustes", "neusten", "letzte", "letztes", "letzten",
                                   "aktuellste", "aktuellstes", "newest", "latest", "recent", "last"]
        let days: [String: Int] = ["heute": 1, "today": 1, "gestern": 2, "yesterday": 2]
        let words = query.split(separator: " ").map { $0.lowercased() }
        guard words.allSatisfy({ photoFiller.contains($0) || newest.contains($0) || days[$0] != nil }) else { return nil }
        return NewestWish(days: words.compactMap { days[$0] }.max())
    }
}
