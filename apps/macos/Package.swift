import PackageDescription

let package = Package(
    name: "Byakaron",
    products: [
        .library(
            name: "Byakaron",
            targets: ["Byakaron"]
        ),
    ],
    targets: [
        .target(
            name: "Byakaron",
            path: "."
        ),
    ],
    swiftLanguageModes: [.v6]
)
