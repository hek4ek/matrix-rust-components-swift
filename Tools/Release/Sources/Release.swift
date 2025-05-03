import ArgumentParser
import CommandLineTools
import Foundation

@main
struct Release: AsyncParsableCommand {
    @Option(help: "The version of the package that is being released.")
    var version: String
    
    @Flag(help: "Prevents the run from pushing anything to GitHub.")
    var localOnly = false
    
    @Flag(help: "Test mode with mock data")
    var testMode = false

    var apiToken: String {
        get {
            if let envToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] {
                Log.info("apiToken from GITHUB_TOKEN")
                return envToken
            }
            else{ 
                Log.info("apiToken try from .netrc")
                if let netrcToken = try? NetrcParser.parse(file: FileManager.default.homeDirectoryForCurrentUser.appending(component: ".netrc"))
                    .authorization(for: URL(string: "https://api.github.com")!)?
                    .password {
                    Log.info("apiToken received from .netrc")
                    return netrcToken
                }
                else {
                    return "GitHub token not found. Set GITHUB_TOKEN env variable or add it to ~/.netrc."
                }
            }
        }
    }    
    var sourceRepo = Repository(owner: "matrix-org", name: "matrix-rust-sdk")
    var packageRepo = Repository(owner: "hek4ek", name: "matrix-rust-components-swift")
    
    var packageDirectory = URL(fileURLWithPath: #file)
        .deletingLastPathComponent() // Release.swift
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // Release
        .deletingLastPathComponent() // Tools
    lazy var buildDirectory = packageDirectory
        .deletingLastPathComponent() // matrix-rust-components-swift
        .appending(component: "matrix-rust-sdk")
    
    mutating func run() async throws {
        let package = Package(repository: packageRepo, directory: packageDirectory, apiToken: apiToken, urlSession: localOnly ? .releaseMock : .shared)
        Zsh.defaultDirectory = package.directory
        
        if testMode {
            // Мок-данные для теста
            let product = BuildProduct(
                sourceRepo: sourceRepo,
                version: version,
                commitHash: "test123",
                branch: "test-branch",
                directory: packageDirectory.appending(component: "test-mock"),
                frameworkName: "MatrixSDKFFI.xcframework"
            )
            
            Log.info("try package.makeRelease()")
            try await package.makeRelease(with: product, uploading: packageDirectory.appending(component: "test.zip"))
            Log.info("try makeRelease()")
            try await makeRelease(with: product, uploading: packageDirectory.appending(component: "test.zip"))
            return
        }

        Log.info("Build directory: \(buildDirectory.path())")
        
        let product = try build()
        let (zipFileURL, checksum) = try package.zipBinary(with: product)
        
        try await updatePackage(package, with: product, checksum: checksum)
        try commitAndPush(package, with: product)
        try await package.makeRelease(with: product, uploading: zipFileURL)
    }
    
    mutating func build() throws -> BuildProduct {
        Log.info("build()")
        let git = Git(directory: buildDirectory)
        Log.info("post Git(directory: buildDirectory)")
        let commitHash = try git.commitHash
        Log.info("post try git.commitHash")
        let branch = try git.branchName
        
        Log.info("Building \(branch) at \(commitHash)")
        
        // unset fixes an issue where swift compilation prevents building for targets other than macOS
        try Zsh.run(command: "unset SDKROOT && cargo xtask swift build-framework --release", directory: buildDirectory)
        
        return BuildProduct(sourceRepo: sourceRepo,
                            version: version,
                            commitHash: commitHash,
                            branch: branch,
                            directory: buildDirectory.appending(component: "bindings/apple/generated/"),
                            frameworkName: "MatrixSDKFFI.xcframework")
    }
    
    func updatePackage(_ package: Package, with product: BuildProduct, checksum: String) async throws {
        Log.info("Copying sources")
        let source = product.directory.appending(component: "swift", directoryHint: .isDirectory)
        let destination = package.directory.appending(component: "Sources/MatrixRustSDK", directoryHint: .isDirectory)
        try Zsh.run(command: "rsync -a --delete '\(source.path())' '\(destination.path())'")
        
        try await package.updateManifest(with: product, checksum: checksum)
    }
    
    func commitAndPush(_ package: Package, with product: BuildProduct) throws {
        Log.info("Pushing changes")
        
        let git = Git(directory: package.directory)
        try git.add(files: "Package.swift", "Sources")
        try git.commit(message: "Bump to version \(version) (\(product.sourceRepo.name)/\(product.branch) \(product.commitHash))")
        
        guard !localOnly else {
            Log.info("Skipping push for --local-only")
            return
        }
        
        try git.push()
    }

func makeRelease(with product: BuildProduct, uploading fileURL: URL) async throws {
    guard !localOnly else {
        Log.info("Skipping release creation for --local-only")
        return
    }
    
    // 1. Инициализируем URLSession
    let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        return URLSession(configuration: config)
    }()
    
    // 2. Формируем запрос
    let url = URL(string: "https://api.github.com/repos/\(packageRepo.owner)/\(packageRepo.name)/releases")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("token \(apiToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    // 3. Подготавливаем данные
    let payload: [String: Any] = [
        "tag_name": product.version,
        "name": product.version,
        "body": "Automated release for \(product.version)",
        "draft": false,
        "prerelease": false
    ]
    
    do {
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        
        // 4. Выполняем запрос
        let (data, response) = try await urlSession.upload(for: request, from: jsonData)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ReleaseError", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Invalid response type"
            ])
        }
        
        // 5. Обрабатываем ответ
        switch httpResponse.statusCode {
        case 200..<300:
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let htmlURL = json["html_url"] as? String {
                Log.info("Release created: \(htmlURL)")
            } else {
                Log.info("Unexpected response format: \(String(data: data, encoding: .utf8) ?? "")")
            }
        default:
            let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
            throw NSError(domain: "ReleaseError", code: httpResponse.statusCode, 
                          userInfo: ["response": errorBody])
        }
    } catch {
        Log.info("Release creation failed: \(error)")
        throw error
    }
}
}
