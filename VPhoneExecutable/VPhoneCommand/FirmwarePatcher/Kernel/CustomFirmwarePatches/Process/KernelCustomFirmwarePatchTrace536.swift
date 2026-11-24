// KernelCustomFirmwarePatchTrace536.swift — CFW kernel patch: sysent[536] argument/return tracer
//
// Wraps the syscall-536 handler (CVE-2026-43724 accounting walker) in a code cave that records
// {cnt1, records, cnt2, entries, return} into a fixed kernel buffer, then calls the original
// handler. The buffer is read from the guest with the existing `krw` primitive.
//
// Cave layout:
//   pacibsp; stp x19,x20; stp x21,x30
//   ldr w8,[x1]; ldr w9,[x1,#8]; ldr w10,[x1,#0x10]; ldr w11,[x1,#0x18]
//   adrp/add x12, LOG; stur the four values
//   mov x0,x19; mov x1,x20; adrp/add x16, ORIG; blr x16
//   stur x0,[x12,#0x20]; stur magic,[x12,#0x28]
//   ldp x21,x30; ldp x19,x20; retab
//
// adrp/add are computed from unslid VAs; both cave and targets share one slide, so the
// PC-relative encoding stays valid at runtime (same technique as kcall10's slide oracle).

import Foundation
import VPhonePatchKit

extension KernelCustomFirmwarePatcher {
    private static let trace536SysentEntrySize = 24
    private static let trace536Magic: UInt64 = 0x5452_4143_3533_36  // "TRAC536"

    @discardableResult
    func patchTrace536() -> Bool {
        log("\n[CFW]trace536: sysent[536] argument/return tracer")

        guard let sysEntOff = findSysentTableForTrace() else {
            log("  [-] sysent table not found")
            return false
        }
        let entry = sysEntOff + 536 * Self.trace536SysentEntrySize
        guard entry + Self.trace536SysentEntrySize <= buffer.count else {
            log("  [-] sysent[536] outside file")
            return false
        }
        let entryNArg = buffer.data.loadLE(UInt16.self, at: entry + 20)
        let entryArgBytes = buffer.data.loadLE(UInt16.self, at: entry + 22)
        guard entryNArg >= 4, entryArgBytes >= 0x10 else {
            log(
                "  [-] sysent[536] takes \(entryNArg) args (\(entryArgBytes) bytes); the tracer needs four 4-byte args"
            )
            return false
        }
        let oldCall = buffer.readU64(at: entry)
        let origFoff = decodeChainedPtrForTrace(oldCall)
        guard origFoff > 0, let origVA = virtualAddressForTrace(forFileOffset: origFoff) else {
            log(
                "  [-] sysent[536].sy_call target not decodable (raw 0x\(String(format: "%X", oldCall)))"
            )
            return false
        }
        guard let logVA = findTraceBufferVA() else {
            log("  [-] no writable zero region found for the trace buffer")
            return false
        }
        guard let caveOff = findCodeCave(size: 0x100) else {
            log("  [-] no code cave")
            return false
        }
        guard let caveVA = virtualAddressForTrace(forFileOffset: caveOff) else {
            log("  [-] cave outside every segment")
            return false
        }

        let cave = Self.buildTrace536Cave(caveVA: caveVA, origVA: origVA, logVA: logVA)
        emit(
            caveOff, cave,
            patchID: "kernel-boot-trace536.cave",
            description: "trace536 cave (logs uap[0..3] + ret to 0x\(String(format: "%X", logVA)))")
        emit(
            entry,
            encodeChainedAuthPtrForTrace(
                targetFoff: caveOff,
                nextVal: extractChainNextForTrace(oldCall),
                diversity: extractChainDiversityForTrace(oldCall),
                key: extractChainKeyForTrace(oldCall),
                addrDiv: extractChainAddrDivForTrace(oldCall)
            ),
            patchID: "kernel-boot-trace536.sy_call",
            description: "sysent[536].sy_call = trace536 cave 0x\(String(format: "%X", caveOff))")
        log(
            "  [+] orig handler foff 0x\(String(format: "%X", origFoff)) va 0x\(String(format: "%X", origVA))"
        )
        log("  [+] trace buffer va 0x\(String(format: "%X", logVA))")
        log(
            "  [+] cave foff 0x\(String(format: "%X", caveOff)) va 0x\(String(format: "%X", caveVA))"
        )
        return true
    }

    // MARK: - Locate a writable zero region (uses the __DATA segment tail)

    private func findTraceBufferVA() -> UInt64? {
        // Only writable data segments. __DATA_CONST is read-only at runtime.
        // Use a verified-zero file-backed tail first; the start of BSS is the
        // first live variable, not padding. A BSS tail is the last resort.
        let writable: Set = ["__DATA", "__DATA_DIRTY"]
        var bssTail: UInt64?
        for seg in segments where writable.contains(seg.name) && seg.vmSize >= 0x100 {
            let tail = (seg.vmAddr + seg.vmSize - 0x100) & ~0xF
            guard tail >= seg.vmAddr, tail + 0x100 <= seg.vmAddr + seg.vmSize else {
                continue
            }
            if let fo = fileOffsetForTrace(forVA: tail), fo + 0x100 <= buffer.count,
                buffer.readBytes(at: fo, count: 0x100).allSatisfy({ $0 == 0 })
            {
                return tail
            }
            if seg.vmSize > seg.fileSize, tail >= seg.vmAddr + seg.fileSize {
                bssTail = tail
            }
        }
        return bssTail
    }

    private func fileOffsetForTrace(forVA va: UInt64) -> Int? {
        for seg in segments where seg.fileSize > 0 {
            if va >= seg.vmAddr, va < seg.vmAddr + seg.fileSize {
                return Int(seg.fileOffset + (va - seg.vmAddr))
            }
        }
        return nil
    }

    // MARK: - Cave builder

    static func buildTrace536Cave(caveVA: UInt64, origVA: UInt64, logVA: UInt64) -> Data {
        var code: [UInt32] = []
        code.append(0xD503_237F)  // pacibsp
        code.append(0xA9BF_53F3)  // stp x19, x20, [sp, #-0x10]!
        code.append(0xA9BF_7BF5)  // stp x21, x30, [sp, #-0x10]!
        code.append(0xAA00_03F3)  // mov x19, x0
        code.append(0xAA01_03F4)  // mov x20, x1
        code.append(0xB940_0288)  // ldr w8,  [x20]
        code.append(0xB940_0689)  // ldr w9,  [x20, #8]
        code.append(0xB940_128A)  // ldr w10, [x20, #0x10]
        code.append(0xB940_0E8B)  // ldr w11, [x20, #0x18]
        let cmnIdx = code.count
        code.append(0x3100_051F)  // cmn w8, #1  (cnt1 == 0xffffffff ?)
        let beqIdx = code.count
        code.append(0x5400_0000)  // b.eq magic  (fixup below)
        code.append(encodeADRP(12, pc: caveVA, target: logVA))
        code.append(encodeADD(12, 12, logVA))
        code.append(0xF800_0188)  // stur x8,  [x12]
        code.append(0xF800_8189)  // stur x9,  [x12, #8]
        code.append(0xF801_018A)  // stur x10, [x12, #0x10]
        code.append(0xF801_818B)  // stur x11, [x12, #0x18]
        code.append(0xAA13_03E0)  // mov x0, x19
        code.append(0xAA14_03E1)  // mov x1, x20
        code.append(encodeADRP(16, pc: caveVA, target: origVA))
        code.append(encodeADD(16, 16, origVA))
        code.append(0xD63F_0200)  // blr x16
        code.append(encodeADRP(12, pc: caveVA, target: logVA))
        code.append(encodeADD(12, 12, logVA))
        code.append(0xF802_0180)  // stur x0, [x12, #0x20]
        let magic = UInt32(truncatingIfNeeded: Self.trace536Magic & 0xFFFF_FFFF)
        code.append(0xD280_0000 | ((magic & 0xFFFF) << 5) | 9)  // movz x9, #lo16
        code.append(0xF2A0_0000 | (((magic >> 16) & 0xFFFF) << 5) | 9)  // movk x9, #hi16, lsl 16
        code.append(0xF802_8189)  // stur x9, [x12, #0x28]
        let epilogueIdx = code.count
        code.append(0xA8C1_7BF5)  // ldp x21, x30, [sp], #0x10
        code.append(0xA8C1_53F3)  // ldp x19, x20, [sp], #0x10
        code.append(0xD65F_0FFF)  // retab
        // magic path: return the buffer's runtime address in x0 (PC-relative, always correct)
        let magicIdx = code.count
        code.append(encodeADRP(0, pc: caveVA, target: logVA))
        code.append(encodeADD(0, 0, logVA))
        let bIdx = code.count
        code.append(0x1400_0000)  // b epilogue (fixup below)
        // branch fixups
        let beqOff = magicIdx - beqIdx
        code[beqIdx] = 0x5400_0000 | (UInt32(beqOff & 0x7FFFF) << 5)
        let bOff = epilogueIdx - bIdx
        code[bIdx] = 0x1400_0000 | UInt32(bOff & 0x3FFFFFF)
        _ = cmnIdx

        var out = Data(capacity: code.count * 4)
        for w in code {
            var le = w.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        return out
    }

    static func encodeADRP(_ rd: UInt32, pc: UInt64, target: UInt64) -> UInt32 {
        let pcPage = pc & ~0xFFF
        let tPage = target & ~0xFFF
        let delta = Int64(bitPattern: tPage &- pcPage) >> 12
        let imm = UInt32(truncatingIfNeeded: delta) & 0x1F_FFFF
        let immlo = imm & 3
        let immhi = (imm >> 2) & 0x7FFFF
        return 0x9000_0000 | (immlo << 29) | (immhi << 5) | rd
    }

    static func encodeADD(_ rd: UInt32, _ rn: UInt32, _ targetVA: UInt64) -> UInt32 {
        0x9100_0000 | (UInt32(targetVA & 0xFFF) << 10) | (rn << 5) | rd
    }

    // MARK: - Local copies of the kcall10 helpers (file-scoped there)

    private func findSysentTableForTrace() -> Int? {
        let execSegNames: Set = ["__TEXT_EXEC", "__TEXT_BOOT_EXEC"]
        var execRanges: [(Int, Int)] = []
        for seg in segments where execSegNames.contains(seg.name) && seg.fileSize > 0 {
            execRanges.append((Int(seg.fileOffset), Int(seg.fileOffset + seg.fileSize)))
        }
        func inExec(_ fo: Int) -> Bool {
            fo > 0 && execRanges.contains { fo >= $0.0 && fo < $0.1 }
        }
        func validEntry(_ o: Int) -> Bool {
            guard o + Self.trace536SysentEntrySize <= buffer.count else { return false }
            guard inExec(decodeChainedPtrForTrace(buffer.readU64(at: o))) else { return false }
            let rt = buffer.data.loadLE(UInt32.self, at: o + 16)
            let narg = buffer.data.loadLE(UInt16.self, at: o + 20)
            let argBytes = buffer.data.loadLE(UInt16.self, at: o + 22)
            return rt <= 9 && narg <= 12 && argBytes <= 96
        }
        var bestBase = -1
        var bestLen = 0
        for seg in segments where seg.name.contains("DATA") && seg.fileSize > 0 {
            let sStart = Int(seg.fileOffset)
            let sEnd = min(sStart + Int(seg.fileSize), buffer.count)
            var off = sStart
            while off + Self.trace536SysentEntrySize <= sEnd {
                if validEntry(off) {
                    let runStart = off
                    var n = 0
                    while off + Self.trace536SysentEntrySize <= sEnd, validEntry(off) {
                        n += 1
                        off += Self.trace536SysentEntrySize
                    }
                    if n > bestLen {
                        bestLen = n
                        bestBase = runStart
                    }
                } else {
                    off += 8
                }
            }
        }
        guard bestLen >= 256, bestBase >= 0 else { return nil }
        return bestBase
    }

    private func virtualAddressForTrace(forFileOffset foff: Int) -> UInt64? {
        for seg in segments where seg.fileSize > 0 {
            let start = Int(seg.fileOffset)
            let end = start + Int(seg.fileSize)
            if foff >= start, foff < end { return seg.vmAddr + UInt64(foff - start) }
        }
        return nil
    }

    private func decodeChainedPtrForTrace(_ raw: UInt64) -> Int {
        guard (raw & (1 << 63)) != 0 else { return -1 }
        let target = Int(raw & 0x3FFF_FFFF)
        guard target > 0, target < buffer.count else { return -1 }
        return target
    }

    private func extractChainNextForTrace(_ raw: UInt64) -> UInt32 {
        UInt32((raw >> 51) & 0xFFF)
    }

    private func extractChainDiversityForTrace(_ raw: UInt64) -> UInt32 {
        UInt32((raw >> 32) & 0xFFFF)
    }

    private func extractChainAddrDivForTrace(_ raw: UInt64) -> UInt32 {
        UInt32((raw >> 48) & 1)
    }

    private func extractChainKeyForTrace(_ raw: UInt64) -> UInt32 {
        UInt32((raw >> 49) & 3)
    }

    private func encodeChainedAuthPtrForTrace(
        targetFoff: Int,
        nextVal: UInt32,
        diversity: UInt32,
        key: UInt32,
        addrDiv: UInt32
    ) -> Data {
        let val: UInt64 =
            (UInt64(targetFoff) & 0x3FFF_FFFF) | (UInt64(diversity & 0xFFFF) << 32)
            | (UInt64(addrDiv & 1) << 48) | (UInt64(key & 3) << 49)
            | (UInt64(nextVal & 0xFFF) << 51) | (1 << 63)
        return withUnsafeBytes(of: val.littleEndian) { Data($0) }
    }
}
