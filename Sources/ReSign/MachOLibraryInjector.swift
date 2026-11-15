import Foundation

enum MachOLibraryInjector {
    static func addingLibrary(_ path: String, to source: Data) throws -> Data {
        guard !path.isEmpty, !path.contains("\0"), path.utf8.count < 1024 else {
            throw ReSignError("共享组兼容库路径无效。")
        }
        var command = Data()
        let size = (24 + path.utf8.count + 1 + 7) & ~7
        let words: [UInt32] = [0xc, UInt32(size), 24, 0, 0, 0]
        for word in words {
            var value = word.littleEndian
            command.append(contentsOf: withUnsafeBytes(of: &value) { Array($0) })
        }
        command.append(contentsOf: path.utf8)
        command.append(Data(repeating: 0, count: size - command.count))

        var result = source
        for slice in try slices(in: source) {
            try insert(command, path: path, in: &result, slice: slice)
        }
        return result
    }

    private static func slices(in data: Data) throws -> [Range<Int>] {
        let magic = try u32(data, at: 0, bigEndian: true)
        guard [0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) else {
            return [0..<data.count]
        }
        let big = magic == 0xcafebabe || magic == 0xcafebabf
        let is64 = magic == 0xcafebabf || magic == 0xbfbafeca
        let count = Int(try u32(data, at: 4, bigEndian: big))
        let stride = is64 ? 32 : 20
        let tableEnd = 8 + count * stride
        guard (1...64).contains(count), tableEnd <= data.count else {
            throw ReSignError("共享组适配失败：FAT Mach-O 头无效。")
        }
        var slices: [Range<Int>] = []
        for index in 0..<count {
            let entry = 8 + index * stride
            let offset: UInt64
            let length: UInt64
            if is64 {
                offset = try u64(data, at: entry + 8, bigEndian: big)
                length = try u64(data, at: entry + 16, bigEndian: big)
            } else {
                offset = UInt64(try u32(data, at: entry + 8, bigEndian: big))
                length = UInt64(try u32(data, at: entry + 12, bigEndian: big))
            }
            guard offset >= UInt64(tableEnd), offset <= UInt64(data.count),
                length >= 32, length <= UInt64(data.count) - offset
            else { throw ReSignError("共享组适配失败：FAT Mach-O 切片越界。") }
            let range = Int(offset)..<Int(offset + length)
            guard !slices.contains(where: { $0.overlaps(range) }) else {
                throw ReSignError("共享组适配失败：FAT Mach-O 切片重叠。")
            }
            slices.append(range)
        }
        return slices
    }

    private static func insert(_ command: Data, path: String, in data: inout Data, slice: Range<Int>) throws {
        let start = slice.lowerBound
        guard slice.count >= 32, try u32(data, at: start) == 0xfeedfacf,
            try u32(data, at: start + 4) == 0x0100000c,
            try u32(data, at: start + 12) == 2
        else {
            throw ReSignError("共享组兼容组件仅支持 arm64／arm64e iOS 可执行文件。")
        }
        let count = Int(try u32(data, at: start + 16))
        let commandSize = Int(try u32(data, at: start + 20))
        let end = start + 32 + commandSize
        guard count < 65536, end <= slice.upperBound else {
            throw ReSignError("共享组适配失败：Mach-O 命令区无效。")
        }
        var cursor = start + 32
        var firstData = slice.upperBound
        var alreadyLinked = false
        for _ in 0..<count {
            guard cursor + 8 <= end else { throw ReSignError("共享组适配失败：Mach-O 命令截断。") }
            let kind = try u32(data, at: cursor)
            let size = Int(try u32(data, at: cursor + 4))
            guard size >= 8, size % 8 == 0, size <= end - cursor else {
                throw ReSignError("共享组适配失败：Mach-O 命令长度无效。")
            }
            if kind == 0x19 {
                guard size >= 72 else { throw ReSignError("共享组适配失败：Mach-O segment 无效。") }
                let fileOffset = try u64(data, at: cursor + 40)
                let fileSize = try u64(data, at: cursor + 48)
                guard fileOffset <= UInt64(slice.count), fileSize <= UInt64(slice.count) - fileOffset else {
                    throw ReSignError("共享组适配失败：Mach-O segment 越界。")
                }
                if fileOffset > 0, fileSize > 0 { firstData = min(firstData, start + Int(fileOffset)) }
                let sections = Int(try u32(data, at: cursor + 64))
                guard sections <= (size - 72) / 80 else {
                    throw ReSignError("共享组适配失败：Mach-O section 无效。")
                }
                for index in 0..<sections {
                    let section = cursor + 72 + index * 80
                    let length = try u64(data, at: section + 40)
                    let offset = Int(try u32(data, at: section + 48))
                    let type = try u32(data, at: section + 64) & 0xff
                    if length == 0 || [1, 0xc, 0x12].contains(type) { continue }
                    guard offset >= 32 + commandSize, offset <= slice.count,
                        length <= UInt64(slice.count - offset)
                    else { throw ReSignError("共享组适配失败：Mach-O section 越界。") }
                    firstData = min(firstData, start + offset)
                }
            } else if [0xc, 0x80000018, 0x8000001f, 0x80000023].contains(kind) {
                guard size >= 24 else { throw ReSignError("共享组适配失败：Mach-O dylib 命令无效。") }
                let nameOffset = Int(try u32(data, at: cursor + 8))
                guard nameOffset >= 24, nameOffset < size,
                    let terminator = data[(cursor + nameOffset)..<(cursor + size)].firstIndex(of: 0)
                else { throw ReSignError("共享组适配失败：Mach-O dylib 路径无效。") }
                let name = String(decoding: data[(cursor + nameOffset)..<terminator], as: UTF8.self)
                if name == path { alreadyLinked = true }
            }
            cursor += size
        }
        guard cursor == end else { throw ReSignError("共享组适配失败：Mach-O 命令总长度不匹配。") }
        if alreadyLinked { return }
        // Use existing header padding so section offsets, fixups and library ordinals stay intact.
        guard commandSize <= Int(UInt32.max) - command.count,
            firstData < slice.upperBound, command.count <= firstData - end,
            data[end..<(end + command.count)].allSatisfy({ $0 == 0 })
        else { throw ReSignError("可执行文件头部没有足够空间加载共享组兼容组件，无法安全重签此 IPA。") }
        data.replaceSubrange(end..<(end + command.count), with: command)
        write(UInt32(count + 1), to: &data, at: start + 16)
        write(UInt32(commandSize + command.count), to: &data, at: start + 20)
    }

    private static func u32(_ data: Data, at offset: Int, bigEndian: Bool = false) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else { throw ReSignError("共享组适配失败：Mach-O 文件截断。") }
        let bytes = (0..<4).map { UInt32(data[offset + $0]) }
        return bigEndian
            ? bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]
            : bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0]
    }

    private static func u64(_ data: Data, at offset: Int, bigEndian: Bool = false) throws -> UInt64 {
        let first = UInt64(try u32(data, at: offset, bigEndian: bigEndian))
        let second = UInt64(try u32(data, at: offset + 4, bigEndian: bigEndian))
        return bigEndian ? first << 32 | second : second << 32 | first
    }

    private static func write(_ value: UInt32, to data: inout Data, at offset: Int) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
    }
}
