import Testing

@testable import container_compose

@Suite("SemVer comparison")
struct SemVerTests {
    @Test("orders by major.minor.patch")
    func ordering() throws {
        #expect(try lt("0.0.2", "0.0.3"))
        #expect(try lt("0.0.9", "0.1.0"))
        #expect(try lt("0.9.0", "1.0.0"))
        #expect(try !lt("0.0.3", "0.0.3"))
        #expect(try !lt("0.1.0", "0.0.9"))
    }

    @Test("a prerelease precedes the same final release")
    func prerelease() throws {
        #expect(try lt("0.0.1-beta1", "0.0.1"))
        #expect(try lt("0.0.0-dev", "0.0.6"))
        #expect(try !lt("0.0.1", "0.0.1-beta1"))
    }

    @Test("tolerates a leading v and short forms")
    func forms() throws {
        #expect(try lt("v0.0.2", "v0.0.3"))
        #expect(try !lt("v1", "v1.0.0"))  // 1 == 1.0.0
        #expect(SemVer("not-a-version") == nil)
    }

    private func lt(_ a: String, _ b: String) throws -> Bool {
        let x = try #require(SemVer(a))
        let y = try #require(SemVer(b))
        return x < y
    }
}
