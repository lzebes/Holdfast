import Foundation

/// Generates the text that must be typed to unlock early. It is random per lock,
/// so it cannot be prepared in advance.
enum Passage {
    static let words: [String] = """
    about above across after again against almost alone along already always among answer another anything \
    around because become before began begin behind being believe below best better between beyond body book \
    both bring brought build call came cannot carry cause certain change child children city clear close cold \
    come common could country course cover cross dark day deep different door down draw during each early earth \
    east easy enough even evening ever every example eye face fact fall family far farm fast father feel feet \
    field figure final find fine fire first follow food force form found four free friend from front full game \
    gave general give gold good govern great green ground group grow half hand happen hard have head hear heard \
    heart heat heavy help here high hold home horse hour house however hundred idea important inside island just \
    keep kind king knew know land language large last late laugh learn leave left less letter life light line \
    list listen little live long look machine made make many mark matter mean measure might mile mind minute \
    money moon more morning most mother mountain move much music must name near need never next night north \
    note nothing notice number object often once only open order other over page paper part pass pattern people \
    perhaps person picture piece place plain plan plant play point port power press problem produce pull question \
    quick quiet rain reach read ready real record remember rest right river road rock room round rule said same \
    school science second seem sentence serve several shape ship short should show side simple since sing size \
    sleep slow small snow some song soon sound south space special stand star start state stay step still stood \
    stop story street strong study such summer sure surface table take talk teach tell than that their them then \
    there these they thing think this those though thought thousand three through time together told took toward \
    town travel tree true turn under unit until upon usual very voice wait walk want warm watch water week weight \
    well west what wheel when where which while white whole wind winter with wonder wood word work world would \
    write year young
    """.split(separator: " ").map(String.init)

    static func generate(wordCount: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        var out: [String] = []
        out.reserveCapacity(wordCount)
        var left = wordCount
        while left > 0 {
            let n = min(left, Int.random(in: 6...13, using: &rng))
            for i in 0..<n {
                var w = words.randomElement(using: &rng)!
                if i == 0 { w = w.prefix(1).uppercased() + w.dropFirst() }
                if i == n - 1 {
                    w += "."
                } else if i > 1, i < n - 2, Int.random(in: 0..<9, using: &rng) == 0 {
                    w += ","
                }
                out.append(w)
            }
            left -= n
        }
        return out.joined(separator: " ")
    }
}
