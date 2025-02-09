import class AppKit.NSBackgroundActivityScheduler
import var AppKit.NSApp
import PMKFoundation
import Foundation
import PromiseKit
import Version
import Path

public class AppUpdater {
    var active = Promise()
#if !DEBUG
    let activity: NSBackgroundActivityScheduler
#endif
    let owner: String
    let repo: String

    var slug: String {
        return "\(owner)/\(repo)"
    }

    public var allowPrereleases = false

    public init(owner: String, repo: String) {
        self.owner = owner
        self.repo = repo
    #if DEBUG
        check().cauterize()
    #else
        activity = NSBackgroundActivityScheduler(identifier: "dev.mxcl.AppUpdater")
        activity.repeats = true
        activity.interval = 24 * 60 * 60
        activity.schedule { [unowned self] completion in
            guard !self.activity.shouldDefer, self.active.isResolved else {
                return completion(.deferred)
            }
            self.check().cauterize().finally {
                completion(.finished)
            }
        }
    #endif
    }

#if !DEBUG
    deinit {
        activity.invalidate()
    }
#endif

    private enum Error: Swift.Error {
        case bundleExecutableURL
        case codeSigningIdentity
        case invalidDownloadedBundle
    }

    public func check(beforeUpdate: (() -> Void)? = nil) -> Promise<Void> {
        guard active.isResolved else {
            return active
        }
        guard Bundle.main.executableURL != nil else {
            return Promise(error: Error.bundleExecutableURL)
        }
        let currentVersion = Bundle.main.version

        func validate(codeSigning b1: Bundle, _ b2: Bundle) -> Promise<Void> {
            return firstly {
                when(fulfilled: b1.codeSigningIdentity, b2.codeSigningIdentity)
            }.done {
                guard $0 == $1 else { throw Error.codeSigningIdentity }
            }
        }

        func update(with asset: Release.Asset) throws -> Promise<Void> {
        #if DEBUG
            print("notice: AppUpdater dry-run:", asset)
            return Promise()
        #else
            let tmpdir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: Bundle.main.bundleURL, create: true)

            return firstly {
                URLSession.shared.downloadTask(.promise, with: asset.browser_download_url, to: tmpdir.appendingPathComponent("download"))
            }.then { dst, _ in
                unzip(dst, contentType: asset.content_type)
            }.compactMap { downloadedAppBundle in
                Bundle(url: downloadedAppBundle)
            }.then { downloadedAppBundle in
                validate(codeSigning: .main, downloadedAppBundle).map{ downloadedAppBundle }
            }.done { downloadedAppBundle in

                // UNIX is cool. Delete ourselves, move new one in then restart.

                let installedAppBundle = Bundle.main
                guard let exe = downloadedAppBundle.executable, exe.exists else {
                    throw Error.invalidDownloadedBundle
                }
                let finalExecutable = installedAppBundle.path/exe.relative(to: downloadedAppBundle.path)

                try installedAppBundle.path.delete()
                try downloadedAppBundle.path.move(to: installedAppBundle.path)
                try FileManager.default.removeItem(at: tmpdir)

                let proc = Process()
                if #available(OSX 10.13, *) {
                    proc.executableURL = finalExecutable.url
                } else {
                    proc.launchPath = finalExecutable.string
                }
                proc.launch()

                // seems to work, though for sure, seems asking a lot for it to be reliable!
                //TODO be reliable! Probably get an external applescript to ask us this one to quit then exec the new one
                NSApp.terminate(self)
            }.ensure {
                _ = try? FileManager.default.removeItem(at: tmpdir)
            }
        #endif
        }

        let url = URL(string: "https://api.github.com/repos/\(slug)/releases")!

        active = firstly {
            URLSession.shared.dataTask(.promise, with: url).validate()
        }.map {
            try JSONDecoder().decode([Release].self, from: $0.data)
        }.compactMap { releases in
            try releases.findViableUpdate(appVersion: currentVersion, repo: self.repo, prerelease: self.allowPrereleases)
        }.then { asset in
            if let beforeUpdate = beforeUpdate {
                beforeUpdate()
            }
            return try update(with: asset)
        }

        return active
    }
}

private struct Release: Decodable {
    let tag_name: String
    let prerelease: Bool
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let content_type: ContentType
    }
    let assets: [Asset]
    var version: Version {
        if let ver = Version(tolerant: tag_name.replacingOccurrences(of: "v", with: "")) {
            return ver
        } else {
            return Version.null
        }
    }

    enum CodingKeys: String, CodingKey {
        case tag_name
        case prerelease
        case assets
    }

    init(from decoder: Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tag_name = try container.decode(String.self, forKey: .tag_name)
            do {
                prerelease = try container.decode(Bool.self, forKey: .prerelease)
            } catch {
                prerelease = false
            }
            do {
                assets = try container.decode([Asset].self, forKey: .assets)
            } catch {
                assets = []
            }
        }
    }

    func viableAsset(forRepo repo: String) -> Asset? {
        return assets.first(where: { (asset) -> Bool in
            let prefix = "\(repo.lowercased())-\(tag_name)"
            let laxprefix = repo.lowercased()
            let name = (asset.name as NSString).deletingPathExtension.lowercased()

            switch (name, asset.content_type) {
            case ("\(prefix).tar", .tar):
                return true
            case ("\(laxprefix).tar", .tar):
                return true
            case (prefix, _):
                return true
            case (prefix, .bin):
                return false
            case (laxprefix, _):
                return true
            default:
                return false
            }
        })
    }
}

private enum ContentType: Decodable {
    init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "application/x-bzip2", "application/x-xz", "application/x-gzip":
            self = .tar
        case "application/zip":
            self = .zip
        case "application/octet-stream":
            self = .bin
        default:
            throw PMKError.badInput
        }
    }

    case zip
    case tar
    case bin
}

extension Release: Comparable {
    static func < (lhs: Release, rhs: Release) -> Bool {
        guard lhs.version.major == rhs.version.major else { return lhs.version.major < rhs.version.major }
        guard lhs.version.minor == rhs.version.minor else { return lhs.version.minor < rhs.version.minor }
        guard lhs.version.patch == rhs.version.patch else { return lhs.version.patch < rhs.version.patch }

        return false
    }

    static func == (lhs: Release, rhs: Release) -> Bool {
        return lhs.tag_name == rhs.tag_name
    }
}

private extension Array where Element == Release {
    func findViableUpdate(appVersion: Version, repo: String, prerelease: Bool) throws -> Release.Asset? {
        let suitableReleases = prerelease ? self : filter{ !$0.prerelease }
        guard let latestRelease = suitableReleases.sorted().last else { return nil }
        guard appVersion < latestRelease.version else { throw PMKError.cancelled }
        return latestRelease.viableAsset(forRepo: repo)
    }
}

private func unzip(_ url: URL, contentType: ContentType) -> Promise<URL> {

    let proc = Process()
    if #available(OSX 10.13, *) {
        proc.currentDirectoryURL = url.deletingLastPathComponent()
    } else {
        proc.currentDirectoryPath = url.deletingLastPathComponent().path
    }

    switch contentType {
    case .tar:
        proc.launchPath = "/usr/bin/tar"
        proc.arguments = ["xf", url.path]
    case .zip:
        proc.launchPath = "/usr/bin/unzip"
        proc.arguments = [url.path]
    default:
        break
    }

    func findApp() throws -> URL? {
        let cnts = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: [.isDirectoryKey], options: .skipsSubdirectoryDescendants)
        for url in cnts {
            guard url.pathExtension == "app" else { continue }
            guard let foo = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, foo else { continue }
            return url
        }
        return nil
    }

    return firstly {
        proc.launch(.promise)
    }.compactMap { _ in
        try findApp()
    }
}

private extension Bundle {
    var isCodeSigned: Guarantee<Bool> {
        let proc = Process()
        proc.launchPath = "/usr/bin/codesign"
        proc.arguments = ["-dv", bundlePath]
        return proc.launch(.promise).map { _ in
            true
        }.recover { _ in
            .value(false)
        }
    }

    var codeSigningIdentity: Promise<String> {
        let proc = Process()
        proc.launchPath = "/usr/bin/codesign"
        proc.arguments = ["-dvvv", bundlePath]

        return firstly {
            proc.launch(.promise)
        }.compactMap {
            String(data: $0.err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        }.map {
            $0.split(separator: "\n")
        }.filterValues {
            $0.hasPrefix("Authority=")
        }.firstValue.map { line in
            String(line.dropFirst(10))
        }
    }
}
