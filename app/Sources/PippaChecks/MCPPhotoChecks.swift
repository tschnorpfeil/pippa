import Foundation
import PippaCore

extension MCPCheckContext {
    func photoChecks() async {
        // MARK: Photos

        await checkAsync("MCP photos_search: dates and count for the model, ids only in the card; one word retried; limits; closed, denied") {
            let s = setup()
            let hit = await call(s.tools, "photos_search", ["query": "Fahrrad"])
            let data = hit.json["data"] as? [String: Any] ?? [:]
            let photos = data["photos"] as? [[String: Any]] ?? []
            let text = (try? JSONSerialization.data(withJSONObject: hit.json)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            // Several words without a hit: once more with the one word that names the thing.
            let wish = await call(s.tools, "photos_search", ["query": "Bilder aus Knokke"])
            let wishData = wish.json["data"] as? [String: Any] ?? [:]
            let none = await call(s.tools, "photos_search", ["query": "Giraffe"])
            let short = await call(s.tools, "photos_search", ["query": "F"])
            let many = await call(s.tools, "photos_search", ["query": "Fahrrad", "limit": 50])
            s.data.photosClosed = true
            let closed = await call(s.tools, "photos_search", ["query": "Fahrrad"])
            s.data.photosClosed = false; s.data.photosPermission = .denied
            let denied = await call(s.tools, "photos_search", ["query": "Fahrrad"])
            return !hit.isError && photos.count == 2 && data["total"] as? Int == 2 && hit.json["untrusted"] as? Bool == true
                && (photos.first?["date"] as? String)?.contains("2026") == true && photos.last?["title"] as? String == "Radtour (Beispiel)"
                && !text.contains("DEMO-0001") && !text.contains("IMG_0101")
                && !wish.isError && wishData["query"] as? String == "Knokke" && wishData["total"] as? Int == 2
                && s.data.photoQueries.prefix(3) == ["Fahrrad", "Bilder aus Knokke", "Knokke"]
                && !none.isError && (((none.json["data"] as? [String: Any])?["photos"] as? [Any])?.isEmpty == true)
                && short.isError && many.isError
                && closed.isError && closed.json["status"] as? String == "unavailable"
                && denied.isError && (denied.json["tell"] as? String)?.contains("Automation") == true
        }
        await checkAsync("MCP photos_search without a search word: the newest by date (PhotoKit), days, wishes like \"neuestes Bild\", denied") {
            let s = setup()
            func data(_ r: (json: [String: Any], isError: Bool, bytes: Int)) -> [String: Any] { r.json["data"] as? [String: Any] ?? [:] }
            let newest = await call(s.tools, "photos_search", ["limit": 1])
            let wish = await call(s.tools, "photos_search", ["query": "neuestes Bild"])
            let recent = await call(s.tools, "photos_search", ["days": 200])
            let yesterday = await call(s.tools, "photos_search", ["query": "Fotos von gestern"])
            let both = await call(s.tools, "photos_search", ["query": "Fahrrad", "days": 3])
            let tooMany = await call(s.tools, "photos_search", ["days": 400])
            s.data.libraryPermission = .denied
            let denied = await call(s.tools, "photos_search", [:])
            return !newest.isError && (data(newest)["photos"] as? [Any])?.count == 1 && data(newest)["query"] == nil && data(newest)["total"] == nil
                && (((data(newest)["photos"] as? [[String: Any]])?.first?["date"] as? String)?.contains("2026") == true)
                && !wish.isError && (data(wish)["photos"] as? [Any])?.count == 4
                && !recent.isError && data(recent)["total"] as? Int == 1 && data(recent)["days"] as? Int == 200
                && !yesterday.isError && data(yesterday)["days"] as? Int == 2 && (data(yesterday)["photos"] as? [Any])?.isEmpty == true
                && both.isError && tooMany.isError
                && denied.isError && denied.json["status"] as? String == "denied" && s.data.photoQueries.isEmpty
        }
        await checkAsync("Photos card: from Pippa's own result (ids, newest first, label), in the read note; previews asked once after the sentence") {
            let notes = Box<PippaMCPReadNote>()
            let asked = Box<String>()
            let demo = DemoIntegrations(granted: true)
            let data = DemoHostData(integrations: demo, now: now)
            data.photosPermission = .notDetermined
            data.libraryPermission = .notDetermined
            let host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: data, askForAccess: true, now: { now },
                                    calendar: berlin, explainAccess: { subject, sentence in asked.append("\(subject.appName)|\(sentence)"); return true },
                                    onRead: { notes.append($0) })
            let tools = PippaMCPTools(host: host)
            _ = await call(tools, "photos_search", ["query": "Knokke", "limit": 1])
            guard case .photos(let card)? = notes.all.first?.card else { return false }
            let empty = setup()
            let nothing = await call(empty.tools, "photos_search", ["query": "Giraffe"])
            return card.items.map(\.id) == ["DEMO-0003/L0/001"] && card.total == 2 && card.previews && card.query == "Knokke"
                && card.items.first?.label == "IMG_0203.HEIC" && card.items.first?.dateLabel.contains("2025") == true
                && card.truncatedNote != nil
                && asked.all == ["\(PhotosLibrary.appName)|\(PippaMCPTools.accessExplanation(.photos))"] && data.previewAsked
                && notes.all.first?.line == L("Searched Photos for “%@”: %lld found", table: "MCP", "Knokke", 2)
                && !nothing.isError && !empty.data.previewAsked && notes.all.count == 1
        }
    }
}
