// swift-tools-version:6.0
import PackageDescription

let addOns = [
    ("ntfy-addon", "AddOns/ntfy"),
    ("imessage-addon", "AddOns/imessage"),
    ("asc-addon", "AddOns/appstoreconnect"),
    ("posthog-addon", "AddOns/posthog"),
    ("macjobs-addon", "AddOns/macjobs"),
    ("scriptfeed-addon", "AddOns/scriptfeed"),
    ("sentry-addon", "AddOns/sentry"),
    ("searchconsole-addon", "AddOns/searchconsole"),
    ("bing-addon", "AddOns/bing"),
    ("youtube-addon", "AddOns/youtube"),
    ("x-addon", "AddOns/x"),
    ("cloudflare-addon", "AddOns/cloudflare"),
    ("revenuecat-addon", "AddOns/revenuecat"),
    ("vercel-addon", "AddOns/vercel"),
]

let package = Package(
    name: "Hmunmawi",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "HmunmawiCore", targets: ["HmunmawiCore"]),
        .library(name: "HmunmawiPluginKit", targets: ["HmunmawiPluginKit"]),
        .executable(name: "Hmunmawi", targets: ["HmunmawiApp"]),
        .executable(name: "hmunmawi-cli", targets: ["hmunmawi-cli"]),
    ] + addOns.map { .executable(name: $0.0, targets: [$0.0]) },
    // Sparkle: in-app updates from a signed feed (MIT licence; see NOTICE).
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "HmunmawiProtocol"),
        .target(name: "HmunmawiCore", dependencies: ["HmunmawiProtocol"]),
        .target(name: "HmunmawiPluginKit", dependencies: ["HmunmawiProtocol"]),
        .executableTarget(
            name: "HmunmawiApp",
            dependencies: ["HmunmawiCore", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.copy("Resources/ai_policy.py"), .copy("Resources/portal.css"), .copy("Resources/portal-nav.css"), .copy("Resources/portal-nav.js")]
        ),
        .executableTarget(name: "hmunmawi-cli"),
        .executableTarget(name: "hm-test-plugin", dependencies: ["HmunmawiPluginKit"], path: "Tests/TestPlugin"),
        .testTarget(name: "HmunmawiCoreTests", dependencies: ["HmunmawiCore", "hm-test-plugin"]),
        .testTarget(name: "HmunmawiAppTests", dependencies: ["HmunmawiApp", "HmunmawiCore"]),
    ] + addOns.map {
        .executableTarget(name: $0.0, dependencies: ["HmunmawiPluginKit"], path: $0.1, exclude: ["manifest.json"])
    }
)
