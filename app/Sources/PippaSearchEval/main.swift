import Foundation
import PippaCore

// Measurement: Pippa's FTS5 index (SearchIndex) vs EmbeddingGemma 2 vs hybrid (reciprocal rank fusion) on the synthetic
// corpus app/Fixtures/search-eval/corpus.json. Embeddings from a local llama-server (--embedding) at PIPPA_EMBED_URL.
// Only synthetic test material; nothing leaves the Mac. Run via scripts/search-eval.sh.

setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment
let fixture = URL(fileURLWithPath: env["PIPPA_SEARCH_CORPUS"] ?? "app/Fixtures/search-eval/corpus.json")
let endpoint = URL(string: env["PIPPA_EMBED_URL"] ?? "http://127.0.0.1:53600/v1/embeddings")!
let dimension = Int(env["PIPPA_EMBED_DIM"] ?? "768") ?? 768

struct Corpus: Decodable {
    struct Document: Decodable { var name: String; var pages: [String] }
    struct Expect: Decodable { var doc: String; var contains: String }
    struct Question: Decodable { var q: String; var kind: String; var expect: [Expect] }
    var documents: [Document]
    var questions: [Question]
}

let clock = ContinuousClock()
func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

func embed(_ texts: [String]) async throws -> [[Float]] {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["input": texts])
    let (data, _) = try await URLSession.shared.data(for: request)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = object["data"] as? [[String: Any]] else {
        throw NSError(domain: "embed", code: 1, userInfo: [NSLocalizedDescriptionKey: String(decoding: data.prefix(300), as: UTF8.self)])
    }
    return rows.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }.map { row in
        let full = (row["embedding"] as? [Double] ?? []).map(Float.init)
        // Matryoshka: keep the leading dimensions, then normalize again (model card).
        let cut = Array(full.prefix(dimension))
        let norm = sqrt(cut.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? cut.map { $0 / norm } : cut
    }
}

func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixture))
let index = try SearchIndex()
let base = URL(fileURLWithPath: "/search-eval", isDirectory: true)
for document in corpus.documents {
    try index.add(DocumentText(url: base.appendingPathComponent(document.name), pages: document.pages, isPaged: document.pages.count > 1, usedOCR: false, headers: [:]))
}
let passages = try index.passages()
print("corpus: \(corpus.documents.count) documents, \(passages.count) sections, \(corpus.questions.count) questions, dimension \(dimension)")

let indexStart = clock.now
var vectors: [[Float]] = []
for batch in stride(from: 0, to: passages.count, by: 16) {
    let slice = passages[batch..<min(batch + 16, passages.count)]
    vectors += try await embed(slice.map { "title: \($0.file.lastPathComponent) | text: \($0.text)" })
}
let indexMs = ms(clock.now - indexStart)
print(String(format: "embedding index: %.0f ms for %d sections (%.1f ms each)", indexMs, passages.count, indexMs / Double(max(passages.count, 1))))

/// 1-based rank of the first expected section, nil if not in the list. "none" questions have no rank.
func rank(_ found: [Passage], _ q: Corpus.Question) -> Int? {
    found.firstIndex { p in q.expect.contains { p.file.lastPathComponent == $0.doc && p.text.contains($0.contains) } }.map { $0 + 1 }
}

struct Score { var at1 = 0, at5 = 0, rr = 0.0 }
var totals: [String: [Score]] = [:]   // kind -> [fts, emb, hyb]
var counts: [String: Int] = [:]
var ftsTimes: [Double] = [], embTimes: [Double] = []
var noneBest: [Float] = [], answerBest: [Float] = []
let k = 60.0
let byID = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, $0) })
for q in corpus.questions {
    let t0 = clock.now
    let fts = try index.search(q.q, limit: 20)
    ftsTimes.append(ms(clock.now - t0))
    let t1 = clock.now
    let qv = try await embed(["task: search result | query: \(q.q)"])[0]
    let scored = passages.indices.map { (i: $0, s: dot(qv, vectors[$0])) }.sorted { $0.s > $1.s }
    embTimes.append(ms(clock.now - t1))
    let emb = scored.prefix(20).map { passages[$0.i] }
    // Reciprocal rank fusion of both lists (k = 60).
    var fused: [Int: Double] = [:]
    for (r, p) in fts.enumerated() { fused[p.id, default: 0] += 1 / (k + Double(r + 1)) }
    for (r, p) in emb.enumerated() { fused[p.id, default: 0] += 1 / (k + Double(r + 1)) }
    let hyb = fused.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.compactMap { byID[$0.key] }
    let best = scored.first?.s ?? 0
    if q.expect.isEmpty { noneBest.append(best); print(String(format: "  [none] best=%.3f fts=%d · %@", best, fts.count, q.q)); continue }
    answerBest.append(best)
    let ranks = [rank(fts, q), rank(emb, q), rank(hyb, q)]
    var t = totals[q.kind] ?? [Score(), Score(), Score()]
    for (m, r) in ranks.enumerated() {
        if let r { t[m].rr += 1 / Double(r); if r == 1 { t[m].at1 += 1 }; if r <= 5 { t[m].at5 += 1 } }
    }
    totals[q.kind] = t; counts[q.kind, default: 0] += 1
    let show = ranks.map { $0.map(String.init) ?? "–" }.joined(separator: "/")
    print("  rank \(show) [\(q.kind)] · \(q.q)")
}
print("\nper kind: hit@1 · hit@5 · MRR for FTS | embedding | hybrid")
var all = [Score(), Score(), Score()]; var n = 0
for (kind, t) in totals.sorted(by: { $0.key < $1.key }) {
    let c = counts[kind]!; n += c
    let cols = t.map { String(format: "%2d/%-2d %2d/%-2d %.2f", $0.at1, c, $0.at5, c, $0.rr / Double(c)) }
    print("  \(kind.padding(toLength: 9, withPad: " ", startingAt: 0)) \(cols.joined(separator: "  |  "))")
    for m in 0..<3 { all[m].at1 += t[m].at1; all[m].at5 += t[m].at5; all[m].rr += t[m].rr }
}
print("  " + "all".padding(toLength: 9, withPad: " ", startingAt: 0) + " " + all.map { String(format: "%2d/%-2d %2d/%-2d %.2f", $0.at1, n, $0.at5, n, $0.rr / Double(n)) }.joined(separator: "  |  "))
func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
print(String(format: "latency per question (median): FTS %.2f ms, embedding (query + scan) %.1f ms", median(ftsTimes), median(embTimes)))
print(String(format: "best cosine: answerable min %.3f · no-answer max %.3f", answerBest.min() ?? 0, noneBest.max() ?? 0))
