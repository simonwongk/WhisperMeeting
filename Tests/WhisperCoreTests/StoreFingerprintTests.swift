import Foundation
import Testing
@testable import WhisperCore

// F190 — the content fingerprint every compare-and-swap in the transaction module is built on.
// Genuinely red without the fix: `StoreFingerprint` does not exist.
//
// What these pin is narrow on purpose. The fingerprint answers "are these the same bytes I
// recorded" against a torn write, a foreign overwrite, a half-restored file or a stale sidecar. It
// is accident detection and makes no claim against an adversary, so there is no test here for
// collision resistance under attack — asserting one would invite a security property to be built on
// a 64-bit non-cryptographic mixer.

@Test("The same bytes always fingerprint the same (F190)")
func storeFingerprintIsStableForIdenticalBytes() {
    let payload = Data("the meeting index, such as it is".utf8)
    #expect(StoreFingerprint.of(payload) == StoreFingerprint.of(payload))
    #expect(StoreFingerprint.of(payload) == StoreFingerprint.of(Data(payload)))
}

@Test("One flipped byte anywhere changes the fingerprint (F190)")
func storeFingerprintChangesOnASingleFlippedByte() {
    // Long enough to exercise the 32-byte block loop AND leave a tail, because a mixer that ignored
    // either would still pass a short-input test. A flip is checked in the first block, in a later
    // block, and in the trailing bytes.
    var payload = Data((0..<200).map { UInt8($0 % 251) })
    let original = StoreFingerprint.of(payload)

    for index in [0, 3, 64, 129, 191, 199] {
        var mutated = payload
        mutated[index] ^= 0x01
        #expect(
            StoreFingerprint.of(mutated) != original,
            "flipping byte \(index) of \(payload.count) did not change the fingerprint"
        )
    }

    // Length is part of the identity: appending a zero byte is not the same payload.
    payload.append(0)
    #expect(StoreFingerprint.of(payload) != original)
}

@Test("Empty data has a stable fingerprint rather than a special case (F190)")
func storeFingerprintHandlesEmptyData() {
    let empty = StoreFingerprint.of(Data())
    #expect(empty == StoreFingerprint.of(Data()))
    #expect(empty.count == 16)
    #expect(empty != StoreFingerprint.of(Data([0])))
}

@Test("A fingerprint is 16 lowercase hex characters and survives Codable (F190)")
func storeFingerprintIsLowercaseHexAndRoundTrips() throws {
    // It is carried inside `GenerationToken` as a `String`, so what has to survive JSON is the
    // string form — and it must be lowercase hex, because a comparison against a differently-cased
    // reimplementation would fail silently rather than loudly.
    let hex = StoreFingerprint.of(Data("payload".utf8))
    #expect(hex.count == 16)
    #expect(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })

    struct Carrier: Codable, Equatable { let fingerprint: String }
    let carrier = Carrier(fingerprint: hex)
    let decoded = try JSONDecoder().decode(
        Carrier.self, from: try JSONEncoder().encode(carrier)
    )
    #expect(decoded == carrier)
}

@Test("Two payloads differing only in byte order fingerprint differently (F190)")
func storeFingerprintIsOrderSensitive() {
    // A mixer that summed or XORed lanes without rotation would collide on a permutation, and two
    // different indexes with the same bytes in a different order is exactly what a reordered save
    // produces.
    #expect(StoreFingerprint.of(Data([1, 2, 3, 4])) != StoreFingerprint.of(Data([4, 3, 2, 1])))
}

// The algorithm is part of the ON-DISK FORMAT, not an implementation detail: a ledger written by one
// build is compared against bytes fingerprinted by another, and `LIBRARY_INDEX_TRANSACTION_DESIGN.md`
// §2.1 states that any reimplementation must produce identical output. Without a golden, a
// well-meaning refactor of the mixer would silently invalidate every ledger on disk — every
// compare-and-swap would report a mismatch, every store would look foreign-overwritten, and the
// symptom would appear nowhere near the change.
//
// These values were produced by the implementation, which is what a golden is. Their job is to make
// changing the mixer LOUD, not to independently prove it correct — the behavioural tests above do
// that. The inputs cover each path through the loop: empty, tail-only, exactly one block, and
// blocks-plus-tail.

@Test("The fingerprint matches its published golden values (F190)")
func storeFingerprintMatchesItsPublishedGoldenValues() {
    let goldens: [(String, Data, String)] = [
        ("empty", Data(), "3e4b04065d2477ff"),
        ("one byte", Data("a".utf8), "0cfa8263a6f0cdd2"),
        ("31 bytes — tail only, no block", Data((0..<31).map { UInt8($0) }), "a4f0f937f661e633"),
        ("32 bytes — exactly one block", Data((0..<32).map { UInt8($0) }), "cf39be82c81c31de"),
        ("100 bytes — blocks plus tail", Data((0..<100).map { UInt8($0) }), "34b6bd87828b245b"),
        ("an index-shaped payload",
         Data(#"[{"id":"A","title":"Quarterly review"}]"#.utf8), "9899e4e313d81d5e"),
    ]
    for (name, payload, expected) in goldens {
        #expect(
            StoreFingerprint.of(payload) == expected,
            "\(name): the mixer changed, which is an ON-DISK FORMAT change — every existing ledger would stop matching its payload. Do not update this value without saying so."
        )
    }
}
