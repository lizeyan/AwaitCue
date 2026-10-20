import Testing
@testable import AwaitCueCore

@Suite("本地隐私排除")
struct PrivacyExclusionRulesTests {
    @Test("bundle ID 使用去空白后的精确匹配")
    func matchesApplicationBundleIdentifiersExactly() {
        let rules = PrivacyExclusionRules(
            applicationBundleIdentifiers: [
                " com.example.Secret ",
                "",
                "com.example.Secret",
            ],
            browserHosts: []
        )

        #expect(rules.excludes(applicationBundleIdentifier: "com.example.Secret"))
        #expect(!rules.excludes(applicationBundleIdentifier: "com.example.Secret.Helper"))
        #expect(rules.applicationBundleIdentifiers == ["com.example.Secret"])
    }

    @Test("浏览器 host 匹配自身和子域但不误匹配相似后缀")
    func matchesBrowserHostAndSubdomains() {
        let rules = PrivacyExclusionRules(
            applicationBundleIdentifiers: [],
            browserHosts: [" Example.COM. ", ".internal.example"]
        )

        #expect(rules.excludes(browserHost: "example.com"))
        #expect(rules.excludes(browserHost: "mail.example.com"))
        #expect(rules.excludes(browserHost: "build.internal.example"))
        #expect(!rules.excludes(browserHost: "evil-example.com"))
        #expect(!rules.excludes(browserHost: "example.com.attacker.invalid"))
        #expect(rules.browserHosts == ["example.com", "internal.example"])
    }

    @Test("空白查询和只含点的 host 不会命中排除规则")
    func emptyQueriesAreNotExcluded() {
        let rules = PrivacyExclusionRules(
            applicationBundleIdentifiers: ["com.example.Secret"],
            browserHosts: ["example.com"]
        )

        #expect(!rules.excludes(applicationBundleIdentifier: " \n"))
        #expect(!rules.excludes(browserHost: "..."))
    }
}
