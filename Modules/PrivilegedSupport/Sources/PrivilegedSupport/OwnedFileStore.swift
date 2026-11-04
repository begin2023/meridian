import Foundation
import Darwin
import CryptoKit

/// All operations stay relative to verified directory descriptors; never follow symlinks.
public final class OwnedFileStore {
    private let directory: Int32
    private let owner: uid_t

    public init(path: String) throws {
        owner = geteuid()
        guard path.hasPrefix("/") else { throw HelperFailure.rejected("必须使用绝对路径。") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw HelperFailure.rejected("无法打开根目录。") }
        do {
            for piece in path.split(separator: "/") {
                let name = String(piece)
                guard name != ".", name != ".." else { throw HelperFailure.rejected("非法目录。") }
                if mkdirat(fd, name, 0o755) != 0 && errno != EEXIST { throw HelperFailure.rejected("无法创建覆盖目录。") }
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                var st = stat()
                guard next >= 0 else { throw HelperFailure.rejected("拒绝符号链接或不可访问目录。") }
                guard fstat(next, &st) == 0, (st.st_uid == 0 || st.st_uid == owner), st.st_mode & 0o022 == 0 else { close(next); throw HelperFailure.rejected("拒绝非可信覆盖目录。") }
                close(fd); fd = next
            }
        } catch { close(fd); throw error }
        directory = fd
    }

    deinit { close(directory) }
    private func valid(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw HelperFailure.rejected("非法文件名。") }
    }
    private func readFile(_ name: String) throws -> Data? {
        try valid(name)
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw HelperFailure.rejected("无法读取覆盖文件。") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == owner, st.st_nlink == 1, st.st_mode & 0o022 == 0, st.st_size >= 0, st.st_size <= 1_048_576 else { throw HelperFailure.rejected("覆盖文件权限或类型不安全。") }
        var bytes = [UInt8](repeating: 0, count: Int(st.st_size))
        let size = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard size == bytes.count else { throw HelperFailure.rejected("覆盖文件读取不完整。") }
        return Data(bytes)
    }
    private func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private func receipt(_ name: String) -> String { ".meridian-" + name + ".sha256" }

    private func checkOwnership(_ name: String) throws -> Bool {
        guard let existing = try readFile(name) else { return false }
        guard let record = try readFile(receipt(name)), record == hash(existing) else {
            throw HelperFailure.rejected("现有覆盖不属于 Meridian，或已被其他软件修改；为保护原文件，已取消。请先由原软件移除或手动备份处理。")
        }
        return true
    }

    public func write(_ data: Data, name: String) throws {
        try valid(name)
        // A receipt that fails to land must not leave a file claiming another
        // owner's contents, so put the previous bytes back.
        let owned = try checkOwnership(name)
        let previous = owned ? try readFile(name) : nil
        // 只有在确认文件属于 Meridian 时才允许覆盖；否则用排他 rename，
        // 期间若有人抢先放了同名文件，宁可失败也不覆盖别人的覆盖。
        try atomicWrite(data, name: name, overwrite: owned)
        do {
            // 回执是本软件自己的元数据，允许覆盖（例如文件被移走但回执还在）。
            try atomicWrite(hash(data), name: receipt(name), overwrite: true)
        } catch {
            if let previous { try? atomicWrite(previous, name: name, overwrite: true) } else { _ = unlinkat(directory, name, 0) }
            throw error
        }
    }

    public func remove(name: String) throws {
        guard try checkOwnership(name) else { return }
        guard unlinkat(directory, name, 0) == 0 else { throw HelperFailure.rejected("无法移除覆盖。") }
        _ = unlinkat(directory, receipt(name), 0)
    }

    private func atomicWrite(_ data: Data, name: String, overwrite: Bool) throws {
        let temporary = ".meridian-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw HelperFailure.rejected("无法写入覆盖文件。") }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        let size = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard size == data.count, fsync(fd) == 0, rename(temporary, name, overwrite: overwrite) == 0 else {
            throw HelperFailure.rejected("保存覆盖文件失败。")
        }
    }

    private func rename(_ temporary: String, _ name: String, overwrite: Bool) -> Int32 {
        if overwrite { return renameat(directory, temporary, directory, name) }
        // RENAME_EXCL 在 macOS 上由 renameatx_np 提供：目标已存在时返回 EEXIST。
        return renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL))
    }
}
