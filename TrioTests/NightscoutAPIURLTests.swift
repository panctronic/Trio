import Foundation
import Testing

@testable import Trio

@Suite("Nightscout API URL Tests") struct NightscoutAPIURLTests {
    private func endpoint(base: String, path: String = "/api/v1/treatments.json") -> String? {
        NightscoutAPI(url: URL(string: base)!).baseComponents(path: path).url?.absoluteString
    }

    @Test("Root URL gets the endpoint path") func rootURL() {
        #expect(endpoint(base: "https://ns.example.com") == "https://ns.example.com/api/v1/treatments.json")
        #expect(endpoint(base: "https://ns.example.com/") == "https://ns.example.com/api/v1/treatments.json")
    }

    @Test("Sub-path is kept") func subPath() {
        #expect(endpoint(base: "https://example.com/ns") == "https://example.com/ns/api/v1/treatments.json")
        #expect(endpoint(base: "https://example.com/ns/") == "https://example.com/ns/api/v1/treatments.json")
        #expect(endpoint(base: "https://example.com/a/b//") == "https://example.com/a/b/api/v1/treatments.json")
    }

    @Test("Port is kept, query and fragment are dropped") func portQueryFragment() {
        #expect(
            endpoint(base: "http://127.0.0.1:17580", path: "/api/v1/entries/sgv.json")
                == "http://127.0.0.1:17580/api/v1/entries/sgv.json"
        )
        #expect(endpoint(base: "https://example.com:8443/ns?x=1#frag") == "https://example.com:8443/ns/api/v1/treatments.json")
    }

    @Test("Query items are appended after the sub-path") func queryItems() {
        var components = NightscoutAPI(url: URL(string: "https://example.com/ns")!)
            .baseComponents(path: "/api/v1/entries/sgv.json")
        components.queryItems = [URLQueryItem(name: "count", value: "10")]
        #expect(components.url?.absoluteString == "https://example.com/ns/api/v1/entries/sgv.json?count=10")
    }
}
