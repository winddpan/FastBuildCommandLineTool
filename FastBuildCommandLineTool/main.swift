import Foundation

func main() {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else {
        print("error arguments:", arguments)
        return
    }

    let start = Date()
    defer { print("fastbuild end", Date().timeIntervalSinceReferenceDate - start.timeIntervalSinceReferenceDate) }
    print("fastbuild start")

    let cacheIndexPath = arguments[2] + "/FastBuildIndexV2.txt"
    let rootDir = arguments[1]

    // read cached index
    let oldIndex: FileIndex
    if let data = try? Data(contentsOf: URL(fileURLWithPath: cacheIndexPath)), let lines = String(data: data, encoding: .utf8)?.components(separatedBy: "\n") {
        oldIndex = FileIndex(files: lines.compactMap { FileData(line: $0) })
    } else {
        oldIndex = FileIndex()
    }
    let newIndex = FileIndex()
    var gitHashMap: [String: String] = [:]

    /*  git diff --diff-filter=d --name-only HEAD
     LiveApp/BundleSettings.swift
     fastlane
     */
    let gitDiff = shellCommand("cd \(rootDir);git diff --diff-filter=d --name-only HEAD").components(separatedBy: "\n")
    let gitDiffSet = Set(gitDiff)

    /* git ls-tree --full-name -r -t HEAD
     160000 commit 8160f60ab6272fa28a5ca8bd31913064f8384564    fastlane
     100644 blob 98481d499213ff76ce230c51a9451e6652f78f90    project.yml
     */
    let lsTree = shellCommand("cd \(rootDir);git ls-tree --full-name -r -t HEAD").components(separatedBy: "\n")
    lsTree.forEach { line in
        let comps = line.components(separatedBy: "\t")
        guard comps.count == 2 else { return }
        let path = comps[1].trimmingCharacters(in: .newlines)
        // filter `gift diff` file
        guard !gitDiffSet.contains(path) else { return }
        let prefix = comps[0].components(separatedBy: " ")
        let hash = prefix[2]
        gitHashMap["\(rootDir)/\(path)"] = hash
    }

    let localFileManager = FileManager()
    let resourceKeys = Set<URLResourceKey>([.isDirectoryKey, .contentModificationDateKey, .creationDateKey, .isSymbolicLinkKey])
    let directoryEnumerator = localFileManager.enumerator(at: URL(fileURLWithPath: rootDir), includingPropertiesForKeys: Array(resourceKeys), options: .skipsHiddenFiles)!
    for case let fileURL as URL in directoryEnumerator {
        guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
              let isSymbolicLinkKey = resourceValues.isSymbolicLink,
              let isDirectory = resourceValues.isDirectory,
              let creationDate = resourceValues.creationDate,
              let modificationDate = resourceValues.contentModificationDate
        else {
            continue
        }
        if isSymbolicLinkKey {
            continue
        }
        if [".xcodeproj", ".xcworkspace", ".framework", ".a"].contains(where: { fileURL.path.contains($0) }) {
            continue
        }
        let path = fileURL.path
        let fileData = FileData(path: path, isDirectory: isDirectory, creationDate: creationDate, modificationDate: modificationDate)
        fileData.gitHash = gitHashMap[path]
        if let old = oldIndex.get(path), old.gitHash != nil, old.gitHash == fileData.gitHash {
            fileData.fileHash = old.fileHash
        }
        newIndex.append(fileData)
    }

    // fullfil file hash
    let runloop = CFRunLoopGetCurrent()
    let group = DispatchGroup()
    var remains = newIndex.allFiles.filter { !$0.isDirectory && $0.fileHash == nil }.map { "'\($0.path)'" }
    let cpuCount = ProcessInfo.processInfo.activeProcessorCount - 1
    let sliceCount = min(Int(ceil(Double(remains.count) / Double(cpuCount))), 3000)
    while !remains.isEmpty {
        let args = "md5 -r " + remains.prefix(sliceCount).joined(separator: " ")
        remains.removeFirst(min(remains.count, sliceCount))
        group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            let result = shellCommand(args)
            for line in result.components(separatedBy: "\n") {
                if let (path, hash) = parseShellMD5(line) {
                    newIndex.get(path)?.fileHash = hash
                }
            }
            group.leave()
        }
    }
    group.notify(queue: DispatchQueue.main) {
        CFRunLoopStop(runloop)
    }
    CFRunLoopRun()

    // compare old/new file hash
    var dateChangeCmds: [String] = []
    oldIndex.allFiles.forEach { old in
        if let new = newIndex.get(old.path),
           new.fileHash != nil,
           old.fileHash != nil,
           new.fileHash == old.fileHash,
           new.modificationDate.accurateToSecond != old.modificationDate.accurateToSecond || new.creationDate.accurateToSecond != old.creationDate.accurateToSecond
        {
            do {
                var attrs = try localFileManager.attributesOfItem(atPath: old.path)
                attrs[.modificationDate] = old.modificationDate
                attrs[.creationDate] = old.creationDate
                try localFileManager.setAttributes(attrs, ofItemAtPath: old.path)
            } catch {
                // avoid file write permission issue
                dateChangeCmds.append("setfile -d '\(cmdDateFormat.string(from: old.creationDate))' '\(old.path)'")
                dateChangeCmds.append("setfile -m '\(cmdDateFormat.string(from: old.modificationDate))' '\(old.path)'")
            }
            new.modificationDate = old.modificationDate
            new.creationDate = old.creationDate
        }
    }
    while !dateChangeCmds.isEmpty {
        let part = dateChangeCmds.prefix(1000)
        dateChangeCmds.removeFirst(min(dateChangeCmds.count, 1000))
        shellCommand(part.joined(separator: ";"))
    }

    let toSave = newIndex.allFiles.map { $0.outputLine() }.joined(separator: "\n")
    do {
        try toSave.data(using: .utf8)?.write(to: URL(fileURLWithPath: cacheIndexPath))
    } catch {
        print(error)
    }
}

main()

/*
 --------------------------
 - Helpers
 --------------------------
 */
class FileIndex {
    private var map: [String: FileData] = [:]

    init() {}

    init(files: [FileData]) {
        files.forEach { append($0) }
    }

    var allFiles: [FileData] {
        return map.map { $0.value }
    }

    func append(_ data: FileData) {
        map[data.path] = data
    }

    func get(_ path: String) -> FileData? {
        return map[path]
    }
}

class FileData {
    private static let SEP = "\t"

    let path: String
    let isDirectory: Bool
    var creationDate: Date
    var modificationDate: Date
    var gitHash: String?
    var fileHash: String?

    required init(path: String, isDirectory: Bool, creationDate: Date, modificationDate: Date) {
        self.path = path
        self.isDirectory = isDirectory
        self.creationDate = creationDate // .accurateToSecond
        self.modificationDate = modificationDate // .accurateToSecond
    }

    init?(line: String) {
        let comps = line.components(separatedBy: FileData.SEP)
        guard comps.count >= 4 else { return nil }
        self.path = comps[0]
        self.isDirectory = comps[1] == "1"
        self.creationDate = Date(timeIntervalSince1970: TimeInterval(comps[2]) ?? 0)
        self.modificationDate = Date(timeIntervalSince1970: TimeInterval(comps[3]) ?? 0)
        if comps.count > 4 {
            self.gitHash = comps[4]
        }
        if comps.count > 5 {
            self.fileHash = comps[5]
        }
    }

    func outputLine() -> String {
        var string = "\(path)\(FileData.SEP)\(isDirectory ? 1 : 0)\(FileData.SEP)\(creationDate.timeIntervalSince1970)\(FileData.SEP)\(modificationDate.timeIntervalSince1970)"
        if let gitHash = gitHash {
            string.append("\(FileData.SEP)\(gitHash)")
        }
        if let fileHash = fileHash {
            string.append("\(FileData.SEP)\(fileHash)")
        }
        return string
    }
}

let cmdDateFormat: DateFormatter = {
    let df = DateFormatter()
    df.locale = .current
    df.timeZone = .current
    df.dateFormat = "MM/dd/yy HH:mm:ss"
    return df
}()

/*
 5bd8f5f464000f7a131e5e8b92e431c6 /Users/panxp/Development/huajian-3/LiveApp/Resource/Assets.xcassets/直播/转转转/gem_turnable_bag.imageset/gem_turnable_bag@2x.png
 */
func parseShellMD5(_ line: String) -> (String, String)? {
    var comps = line.components(separatedBy: " ")
    guard comps.count >= 2 else { return nil }
    let hash = comps.removeFirst()
    let path = comps.joined(separator: " ").trimmingCharacters(in: .newlines)
    return (path, hash)
}

public func BKDRHash(_ text: String) -> Int64 {
    let seed2 = CGFloat(137.0)
    let maxSafeInteger = 9007199254740991.0 / CGFloat(137.0)
    var hash = CGFloat(0)
    for char in text {
        if let scl = String(char).unicodeScalars.first?.value {
            if hash > maxSafeInteger {
                hash = hash / seed2
            }
            hash = hash * CGFloat(131.0) + CGFloat(scl)
        }
    }
    return Int64(hash)
}

@discardableResult
func shellCommand(_ command: String) -> String {
    let task = Process()
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    task.arguments = ["-c", command]
    task.launchPath = "/bin/zsh"
    task.launch()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return output
}

extension Date {
    var accurateToSecond: Date {
        Date(timeIntervalSinceReferenceDate: floor(timeIntervalSinceReferenceDate))
    }
}
