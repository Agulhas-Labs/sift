//
// Copyright © Agulhas Labs
//

/// The pairs `dupes` kept, joined into groups by complete linkage: two groups join only where every pair across them was kept, so no member is in a group with one it is not itself close to.
///
/// Single linkage, which read `A~B, B~C` as one group of three whatever `A` and `C` had in common, chained forty-odd bodies alike only pairwise into one group on this repository's own tree. Here pairs are taken closest first, ties by their indices so every run builds the same groups, and a pair whose two sides cannot join leaves them where they are.
struct DupesClustering {
    /// Each group's indices, ascending, in the order the groups were opened.
    let groups: [[Int]]
    /// Every kept pair's hit, by its indices.
    let scores: [DupesSearch.IndexPair: SimilarHit]
    /// Declarations with at least one kept pair that ended in no group: every partner they had joined a group some member of which they were not close to.
    let strays: Int

    init(pairs: [DupesSearch.ScoredPair]) {
        var scores: [DupesSearch.IndexPair: SimilarHit] = [:]
        for pair in pairs {
            scores[DupesSearch.IndexPair(low: pair.low, high: pair.high)] = pair.hit
        }
        let ordered = pairs.sorted { left, right in
            left.hit.score == right.hit.score ? (left.low, left.high) < (right.low, right.high) : left.hit.score > right.hit.score
        }
        var groupOf: [Int: Int] = [:]
        var members: [[Int]] = []
        func allLinked(_ left: [Int], _ right: [Int]) -> Bool {
            left.allSatisfy { one in
                right.allSatisfy { other in scores[DupesSearch.IndexPair(low: min(one, other), high: max(one, other))] != nil }
            }
        }
        for pair in ordered {
            switch (groupOf[pair.low], groupOf[pair.high]) {
            case (nil, nil):
                groupOf[pair.low] = members.count
                groupOf[pair.high] = members.count
                members.append([pair.low, pair.high])
            case let (joined?, nil) where allLinked(members[joined], [pair.high]):
                groupOf[pair.high] = joined
                members[joined].append(pair.high)
            case let (nil, joined?) where allLinked(members[joined], [pair.low]):
                groupOf[pair.low] = joined
                members[joined].append(pair.low)
            case let (left?, right?) where left != right && allLinked(members[left], members[right]):
                for index in members[right] {
                    groupOf[index] = left
                }
                members[left].append(contentsOf: members[right])
                members[right] = []
            default:
                break
            }
        }
        let paired = Set(pairs.flatMap { [$0.low, $0.high] })
        groups = members.filter { !$0.isEmpty }.map { $0.sorted() }
        self.scores = scores
        strays = paired.count - groupOf.count
    }
}
