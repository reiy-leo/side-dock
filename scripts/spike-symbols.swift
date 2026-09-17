// 枚举 SkyLight 的导出符号，用来查「某个能力到底有没有对应的私有 API」。
//
// 为什么需要它：`nm` 在磁盘上找不到 SkyLight —— 现代 macOS 的框架二进制在 dyld 共享缓存里，
// 磁盘路径下没有真实文件。所以只能在**进程内**解析已加载镜像的 Mach-O 表。
//
// 关键坑：`LC_SYMTAB.symoff` / `stroff` 是**共享缓存内的文件偏移**，不是 vmaddr。
// 必须先经 `__LINKEDIT` 换算（`fileAddr = linkedit_vmaddr + (off - linkedit_fileoff)`），
// 再用「首个 __TEXT 段的 vmaddr」把 vmaddr 折成相对镜像基址的指针。直接拿 symoff 当指针会 SIGSEGV。
//
// 用法：
//   swift scripts/spike-symbols.swift                  # 列默认关键词
//   swift scripts/spike-symbols.swift Transition Cube  # 只列含这些关键词的符号
//
// 只读，不加载不调用任何私有函数，零权限。

import Foundation

let LC_SEGMENT_64: UInt32 = 0x19
let LC_SYMTAB: UInt32 = 0x2

struct Segment64 {
    var cmd: UInt32
    var cmdsize: UInt32
    var segname: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                  CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)
    var vmaddr: UInt64
    var vmsize: UInt64
    var fileoff: UInt64
    var filesize: UInt64
    var maxprot: Int32
    var initprot: Int32
    var nsects: UInt32
    var flags: UInt32
}

struct SymtabCommand {
    var cmd: UInt32
    var cmdsize: UInt32
    var symoff: UInt32
    var nsyms: UInt32
    var stroff: UInt32
    var strsize: UInt32
}

struct Nlist64 {
    var n_strx: UInt32
    var n_type: UInt8
    var n_sect: UInt8
    var n_desc: UInt16
    var n_value: UInt64
}

func segmentName(_ segname: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                              CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)) -> String {
    withUnsafeBytes(of: segname) { raw in
        String(raw.prefix(while: { $0 != 0 }).map { Character(UnicodeScalar($0)) })
    }
}

// MARK: - 找到 SkyLight 镜像

var skyIndex: UInt32?
for i in 0..<_dyld_image_count() {
    guard let name = _dyld_get_image_name(i) else { continue }
    if String(cString: name).contains("SkyLight.framework") { skyIndex = i; break }
}
guard let idx = skyIndex,
      let headerPtr = _dyld_get_image_header(idx),
      let imageName = _dyld_get_image_name(idx) else {
    FileHandle.standardError.write(Data("找不到 SkyLight 镜像（本机可能没有这个私有框架）\n".utf8))
    exit(1)
}
print("镜像：\(String(cString: imageName))")
print("slide：0x\(String(_dyld_get_image_vmaddr_slide(idx), radix: 16))")

let base = UnsafeRawPointer(headerPtr)
let header = base.assumingMemoryBound(to: mach_header_64.self).pointee

// MARK: - 遍历 load commands，取 __LINKEDIT / __TEXT / LC_SYMTAB

var symtab: SymtabCommand?
var linkeditVM: UInt64 = 0
var linkeditFile: UInt64 = 0
var textVM: UInt64 = 0

var cmdPtr = base.advanced(by: MemoryLayout<mach_header_64>.size)
for _ in 0..<header.ncmds {
    let cmd = cmdPtr.assumingMemoryBound(to: UInt32.self).pointee
    let cmdsize = cmdPtr.advanced(by: 4).assumingMemoryBound(to: UInt32.self).pointee
    if cmd == LC_SEGMENT_64 {
        let seg = cmdPtr.assumingMemoryBound(to: Segment64.self).pointee
        let name = segmentName(seg.segname)
        if name == "__LINKEDIT" { linkeditVM = seg.vmaddr; linkeditFile = seg.fileoff }
        if name == "__TEXT" && textVM == 0 { textVM = seg.vmaddr }
    } else if cmd == LC_SYMTAB {
        symtab = cmdPtr.assumingMemoryBound(to: SymtabCommand.self).pointee
    }
    cmdPtr = cmdPtr.advanced(by: Int(cmdsize))
}

guard let st = symtab, linkeditVM != 0, textVM != 0 else {
    FileHandle.standardError.write(Data("缺 LC_SYMTAB / __LINKEDIT / __TEXT，无法解析\n".utf8))
    exit(1)
}

/// 共享缓存里的文件偏移 → vmaddr
func vmaddr(forFileOffset off: UInt32) -> UInt64 {
    linkeditVM + (UInt64(off) - linkeditFile)
}
/// vmaddr → 镜像内指针（以首个 __TEXT 段的 vmaddr 为基）
func ptr(atVM vm: UInt64) -> UnsafeRawPointer {
    base.advanced(by: Int(Int64(bitPattern: vm) - Int64(bitPattern: textVM)))
}

let syms = ptr(atVM: vmaddr(forFileOffset: st.symoff)).assumingMemoryBound(to: Nlist64.self)
let strtab = ptr(atVM: vmaddr(forFileOffset: st.stroff)).assumingMemoryBound(to: CChar.self)

var names: [String] = []
names.reserveCapacity(Int(st.nsyms))
for i in 0..<Int(st.nsyms) {
    let s = syms[i]
    guard s.n_strx != 0 else { continue }
    let name = String(cString: strtab.advanced(by: Int(s.n_strx)))
    if !name.isEmpty { names.append(name) }
}
print("导出符号总数：\(names.count)")

// MARK: - 按关键词筛选

let args = Array(CommandLine.arguments.dropFirst())
let keywords = args.isEmpty
    ? ["Animation", "Animating", "Transition", "Cube", "SwitchSpace", "SetCurrentSpace", "Workspace"]
    : args

for k in keywords {
    let hits = names.filter { $0.contains(k) }.sorted()
    print("\n### 含「\(k)」的符号（\(hits.count) 个）")
    for n in hits { print("  \(n)") }
}

print("""

提示：符号存在 ≠ 能安全调用。签名未知的私有函数猜错参数会直接 SIGSEGV
（实测 `SLSWillSwitchSpaces` 就是），**不要拿用户的图形会话去试错**。
""")
