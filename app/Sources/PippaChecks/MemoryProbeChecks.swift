import Foundation
import PippaCore

/// The memory probe's date window, access states, sampling and privacy. Synthetic stand-ins only: no real Photos
/// library or calendar is read, and the live PhotoKit reader is not called.
func runMemoryProbeChecks() async {
    func zone(_ id: String) -> TimeZone { TimeZone(identifier: id)! }
    let berlin = zone("Europe/Berlin")
    func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ zone: TimeZone = berlin) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = zone
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    func window(_ from: String, _ to: String, in tz: TimeZone = berlin) -> MemoryProbe.Window? {
        try? MemoryProbe.window(from: from, to: to, timeZone: tz)
    }
    let week = window("2026-10-01", "2026-10-08")!

    // Stand-in for PhotoKit that records how often it was read.
    final class Photos: @unchecked Sendable {
        let access: MemoryProbe.PhotoAccess
        let result: Result<MemoryProbe.PhotoSample, Error>
        let reads = LockedBox<[(DateInterval, Int)]>([])
        init(_ access: MemoryProbe.PhotoAccess, _ result: Result<MemoryProbe.PhotoSample, Error> = .success(.init(visibleTotal: 0, sampled: 0, withValidLocation: 0, favorites: 0))) {
            self.access = access; self.result = result
        }
        var source: MemoryProbe.PhotoSource {
            .init(access: { self.access }, sample: { interval, limit in self.reads.mutate { $0.append((interval, limit)) }; return try self.result.get() })
        }
    }
    struct SentinelError: Error, CustomStringConvertible { var description: String { "SENTINEL-ERROR-/Users/someone/Pictures" } }
    func calendar(_ access: IntegrationAccess = .granted, events: [CalendarEvent] = [], fails: Bool = false) -> DemoIntegrations {
        let demo = DemoIntegrations(granted: false)
        demo.set(.calendar, access)
        demo.calendarEvents = events
        demo.calendarFails = fails
        return demo
    }
    func event(_ day: Int, status: CalendarEvent.Status = .confirmed, location: String? = nil) -> CalendarEvent {
        CalendarEvent(id: "SENTINEL-ID-\(day)", title: "SENTINEL-TITLE-\(day)", start: at(2026, 10, day, 9), end: at(2026, 10, day, 10),
                      calendar: "SENTINEL-CALENDAR", status: status, location: location)
    }
    func sample(total: Int, sampled: Int, located: Int = 0, favorites: Int = 0) -> Result<MemoryProbe.PhotoSample, Error> {
        .success(.init(visibleTotal: total, sampled: sampled, withValidLocation: located, favorites: favorites))
    }
    func report(_ photos: Photos, _ integrations: DemoIntegrations, limit: Int = MemoryProbe.sampleLimit) async -> [String: Any] {
        let report = await MemoryProbe.run(week, photos: photos.source, integrations: integrations, limit: limit)
        return (try? JSONSerialization.jsonObject(with: Data(report.json().utf8))) as? [String: Any] ?? [:]
    }
    func source(_ json: [String: Any], _ name: String) -> [String: Any] { json[name] as? [String: Any] ?? [:] }

    // MARK: Date window

    check("Memory probe: [from, to) in the stated time zone, from the first moment of 'from' to the first moment of 'to'") {
        let w = window("2026-10-01", "2026-10-08")
        let newYork = window("2026-10-01", "2026-10-08", in: zone("America/New_York"))
        return w?.interval == DateInterval(start: at(2026, 10, 1), end: at(2026, 10, 8)) && w?.days == 7 && w?.timeZone == "Europe/Berlin"
            && window("2026-10-01", "2026-10-02")?.days == 1
            && newYork?.interval.start == at(2026, 10, 1, 0, zone("America/New_York")) && newYork?.interval.start != w?.interval.start
            && newYork?.timeZone == "America/New_York"
    }
    check("Memory probe: clock changes count as calendar days (23 h and 25 h days), 31 days across a change is allowed") {
        let spring = window("2026-03-28", "2026-03-30"), autumn = window("2026-10-24", "2026-10-26")
        return spring?.days == 2 && spring.map { $0.interval.duration } == 47 * 3600
            && autumn?.days == 2 && autumn.map { $0.interval.duration } == 49 * 3600
            && window("2026-03-15", "2026-04-15")?.days == 31 && window("2026-03-15", "2026-04-16") == nil
            && window("2026-10-01", "2026-11-01")?.days == 31 && window("2026-10-01", "2026-11-02") == nil
    }
    check("Memory probe: empty, reversed, overlong and impossible dates are rejected") {
        let bad: [(String, String)] = [("2026-10-08", "2026-10-01"), ("2026-10-01", "2026-10-01"), ("2026-01-01", "2026-03-01"),
                                       ("2026-02-30", "2026-03-05"), ("2026-02-27", "2026-02-30"), ("2026-13-01", "2026-13-05"),
                                       ("2026-1-01", "2026-01-05"), ("20261001", "20261008"), ("2026-10-01T00:00:00Z", "2026-10-08"),
                                       ("2026-10-01", ""), ("", "2026-10-08"), ("+026-10-01", "2026-10-08"), ("٢٠٢٦-١٠-٠١", "2026-10-08")]
        return bad.allSatisfy { window($0.0, $0.1) == nil } && window("2028-02-28", "2028-03-01")?.days == 2
    }
    check("Memory probe: missing, repeated and unknown arguments fail with a message, --help prints the usage") {
        func fails(_ arguments: [String]) -> Bool { (try? MemoryProbe.parse(arguments, timeZone: berlin)) == nil }
        let valid = ["--memory-probe", "--from", "2026-10-01", "--to", "2026-10-08"]
        guard case .run(let parsed)? = try? MemoryProbe.parse(valid, timeZone: berlin), parsed == week,
              case .run(let reordered)? = try? MemoryProbe.parse(["--to", "2026-10-08", "--from", "2026-10-01", "--memory-probe"], timeZone: berlin),
              reordered == week, case .help? = try? MemoryProbe.parse(["--memory-probe", "--help"]) else { return false }
        return fails(["--memory-probe"]) && fails(["--memory-probe", "--from", "2026-10-01"]) && fails(["--memory-probe", "--to", "2026-10-08"])
            && fails(["--from", "2026-10-01", "--to", "2026-10-08"]) && fails(valid + ["--extra"]) && fails(valid + ["--from", "2026-10-02"])
            && fails(valid + ["--memory-probe"]) && fails(["--memory-probe", "--from", "--to", "2026-10-08"]) && fails(valid + ["2026-10-09"])
            && fails(["--memory-probe", "--from=2026-10-01", "--to=2026-10-08"]) && fails(["--memory-probe", "--from"])
    }
    await checkAsync("Memory probe: an invalid command exits 2 with usage on stderr and reads nothing; a valid one prints JSON") {
        let photos = Photos(.authorized), demo = calendar()
        for arguments in [["--memory-probe"], ["--memory-probe", "--from", "2026-10-08", "--to", "2026-10-01"], ["--memory-probe", "--bogus"],
                          ["--memory-probe", "--from", "2026-01-01", "--to", "2026-12-31"]] {
            let result = await MemoryProbe.execute(arguments, photos: photos.source, integrations: demo, timeZone: berlin)
            guard result.exitCode == 2, result.stdout.isEmpty, result.stderr.contains("usage: Pippa --memory-probe") else { return false }
        }
        let help = await MemoryProbe.execute(["--memory-probe", "--help"], photos: photos.source, integrations: demo, timeZone: berlin)
        guard photos.reads.value.isEmpty, demo.calendarReads.isEmpty, help.exitCode == 0, help.stdout == MemoryProbe.usage else { return false }
        let ok = await MemoryProbe.execute(["--memory-probe", "--from", "2026-10-01", "--to", "2026-10-08"], photos: photos.source, integrations: demo, timeZone: berlin)
        let json = (try? JSONSerialization.jsonObject(with: Data(ok.stdout.utf8))) as? [String: Any]
        return ok.exitCode == 0 && ok.stderr.isEmpty && json?["probe"] as? String == "memory-probe" && photos.reads.value.count == 1 && demo.calendarReads == [week.interval]
    }

    // MARK: Access states stay distinct

    await checkAsync("Memory probe: authorized, limited, not determined, denied and restricted Photos are five different states; only reads carry counts") {
        var statuses: [String] = []
        for access in [MemoryProbe.PhotoAccess.authorized, .limited, .notDetermined, .denied, .restricted] {
            let photos = Photos(access, sample(total: 4, sampled: 4))
            let json = await report(photos, calendar())
            let s = source(json, "photos")
            statuses.append(s["status"] as? String ?? "")
            let read = access == .authorized || access == .limited
            guard (s["sampled"] != nil) == read, (s["visibleTotal"] != nil) == read, (s["truncated"] != nil) == read, (s["elapsedMs"] != nil) == read,
                  photos.reads.value.count == (read ? 1 : 0) else { return false }
        }
        return statuses == ["read", "readLimited", "notDetermined", "denied", "restricted"]
    }
    await checkAsync("Memory probe: limited Photos keeps its visible-scope wording, a full read has none") {
        let limited = source(await report(Photos(.limited, sample(total: 3, sampled: 3)), calendar()), "photos")
        let full = source(await report(Photos(.authorized, sample(total: 3, sampled: 3)), calendar()), "photos")
        return (limited["scope"] as? String)?.contains("limited access") == true && full["scope"] == nil
    }
    await checkAsync("Memory probe: calendar not determined, denied, unavailable and a failed read are not an empty calendar") {
        var results: [String] = []
        for demo in [calendar(.notDetermined), calendar(.denied), calendar(.unavailable("SENTINEL-REASON")), calendar(fails: true), calendar()] {
            let photos = Photos(.authorized)
            let s = source(await report(photos, demo), "calendar")
            results.append("\(s["status"] as? String ?? "")/\(s["sampled"] != nil)")
        }
        return results == ["notDetermined/false", "denied/false", "failed/false", "failed/false", "read/true"]
    }
    await checkAsync("Memory probe: a failing source does not hide the other one, and no error text is reported") {
        let photos = Photos(.authorized, .failure(SentinelError()))
        let json = await report(photos, calendar(events: [event(2), event(3)]))
        let text = String(decoding: (try? JSONSerialization.data(withJSONObject: json)) ?? Data(), as: UTF8.self)
        return source(json, "photos")["status"] as? String == "failed" && source(json, "photos")["sampled"] == nil
            && source(json, "calendar")["status"] as? String == "read" && source(json, "calendar")["sampled"] as? Int == 2
            && !text.contains("SENTINEL") && !text.contains("/Users")
    }

    // MARK: Counts and sampling

    await checkAsync("Memory probe: a successful empty read is a read of zero, with the window and limit stated") {
        let json = await report(Photos(.authorized), calendar())
        let range = json["range"] as? [String: Any]
        for name in ["photos", "calendar"] {
            let s = source(json, name)
            guard s["status"] as? String == "read", s["visibleTotal"] as? Int == 0, s["sampled"] as? Int == 0, s["truncated"] as? Bool == false else { return false }
        }
        return range?["from"] as? String == "2026-10-01" && range?["to"] as? String == "2026-10-08" && range?["timeZone"] as? String == "Europe/Berlin"
            && range?["days"] as? Int == 7 && json["sampleLimit"] as? Int == 500 && json["readElapsedMs"] as? Int != nil
            && (json["notes"] as? [String])?.contains { $0.contains("without a creation date") } == true
            && (json["notes"] as? [String])?.contains { $0.contains("no application timeout") } == true
    }
    await checkAsync("Memory probe: truncated reads say visible total versus sampled, counts and limits use the sampled denominator") {
        let photos = Photos(.authorized, sample(total: 1200, sampled: 500, located: 320, favorites: 12))
        let events = [event(1, location: "SENTINEL-PLACE"), event(2, status: .tentative), event(3, status: .cancelled, location: "  "), event(4), event(5, location: "x")]
        let demo = calendar(events: events)
        let json = await report(photos, demo)
        let p = source(json, "photos"), c = source(json, "calendar")
        // The same calendar with a limit of 3: the first three by start are counted, the other two only in the total.
        let small = await report(Photos(.authorized), demo, limit: 3)
        let s = source(small, "calendar")
        return p["visibleTotal"] as? Int == 1200 && p["sampled"] as? Int == 500 && p["truncated"] as? Bool == true
            && p["withValidLocation"] as? Int == 320 && p["favorites"] as? Int == 12
            && c["visibleTotal"] as? Int == 5 && c["sampled"] as? Int == 5 && c["truncated"] as? Bool == false && c["withLocationText"] as? Int == 2
            && s["visibleTotal"] as? Int == 5 && s["sampled"] as? Int == 3 && s["truncated"] as? Bool == true
            && s["withLocationText"] as? Int == 1 && s["byStatus"] as? [String: Int] == ["confirmed": 1, "tentative": 1, "cancelled": 1]
            && small["sampleLimit"] as? Int == 3
    }
    await checkAsync("Memory probe: a reader can never make the sample larger than the limit or the total") {
        let json = await report(Photos(.authorized, sample(total: 10, sampled: 99, located: 99, favorites: 99)), calendar(), limit: 4)
        let p = source(json, "photos")
        return p["sampled"] as? Int == 4 && p["visibleTotal"] as? Int == 10 && p["truncated"] as? Bool == true
            && p["withValidLocation"] as? Int == 4 && p["favorites"] as? Int == 4
    }
    await checkAsync("Memory probe: only the requested window is read, once per source, with the default limit of 500") {
        let photos = Photos(.authorized), demo = calendar(events: [event(2)])
        _ = await report(photos, demo)
        return photos.reads.value.count == 1 && photos.reads.value[0].0 == week.interval && photos.reads.value[0].1 == 500
            && demo.calendarReads == [week.interval] && MemoryProbe.sampleLimit == 500
    }
    await checkAsync("Memory probe: elapsed time is the measured read time, per source and in total") {
        // Clock reads in order: start, photos done, calendar start, calendar done, all done.
        let ticks = LockedBox<[TimeInterval]>([100, 100.25, 100.25, 102.25, 102.5])
        let clock: @Sendable () -> TimeInterval = { var tick = 0.0; ticks.mutate { tick = $0.isEmpty ? 0 : $0.removeFirst() }; return tick }
        let report = await MemoryProbe.run(week, photos: Photos(.authorized, sample(total: 1, sampled: 1)).source, integrations: calendar(events: [event(2)]), uptime: clock)
        return report.photos.elapsedMs == 250 && report.calendar.elapsedMs == 2000 && report.readElapsedMs == 2500
    }

    // MARK: Privacy

    await checkAsync("Memory probe: titles, calendar names, identifiers, locations, coordinates, exact times and error text never appear") {
        let events = [event(2, location: "SENTINEL-PLACE-Hauptstraße 1"), event(3, status: .tentative, location: "SENTINEL-PLACE-2")]
        let json = await MemoryProbe.run(week, photos: Photos(.limited, sample(total: 2, sampled: 2, located: 1, favorites: 1)).source,
                                         integrations: calendar(events: events)).json()
        let leaked = ["SENTINEL", "Hauptstraße", "T09:00", "2026-10-02", "2026-10-03"]
        let keys = Set(allKeys(try JSONSerialization.jsonObject(with: Data(json.utf8))))
        let allowed: Set<String> = ["probe", "range", "from", "to", "semantics", "timeZone", "days", "sampleLimit", "sampleOrder", "photos", "calendar",
                                    "status", "scope", "visibleTotal", "sampled", "truncated", "elapsedMs", "withValidLocation", "favorites",
                                    "withLocationText", "byStatus", "confirmed", "tentative", "readElapsedMs", "notes"]
        return leaked.allSatisfy { !json.contains($0) } && keys.isSubset(of: allowed)
    }
}

private func allKeys(_ value: Any) -> [String] {
    if let object = value as? [String: Any] { return object.keys.flatMap { [$0] + allKeys(object[$0]!) } }
    if let array = value as? [Any] { return array.flatMap(allKeys) }
    return []
}
