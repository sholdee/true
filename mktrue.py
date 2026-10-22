#!/usr/bin/env python3
"""Generate the smallest x86-64 Linux ELF executables that behave like /bin/true,
or like `sleep infinity` (the pause-* variants).

A static ELF64 needs a 64-byte ELF header and one 56-byte program header. The
code (`mov al,60 ; syscall`, 4 bytes, relying on rax=rdi=0 at process entry) is
the only other content, so the naive floor is 124 bytes. Everything below that
comes from starting the program header *inside* the ELF header, so that every
program-header field lands on an ELF-header field the loader does not read.

Layouts, by program-header offset (phoff):

  true-112  phoff=0x38  p_type <- e_phnum|e_shentsize<<16, p_flags <- e_shnum (5).
                        All ELF-header fields valid except e_shnum.
  true-104  phoff=0x30  p_type <- e_flags, p_flags <- e_ehsize|e_phentsize<<16,
                        p_offset <- e_phnum = 1 (so p_vaddr ends in ...001).
  true-103  phoff=0x2f  p_type[0] <- e_shoff[7]; p_flags straddles e_flags, e_ehsize
                        and e_phentsize; p_offset <- e_phnum<<8 = 0x100.
  true-80   phoff=0x18  p_type <- e_entry[0:4] (=1) and p_flags <- e_entry[4:8] (=5),
                        so e_entry = 0x5_00000001 and the entry is file offset 1:
                        the bytes 'ELF' are REX prefixes, code sits in the e_ident
                        padding. ET_EXEC.
  true-75   phoff=0x0c  ET_DYN: e_type=3 makes p_flags carry PF_X. e_entry equals
                        p_vaddr's page, so the entry is file offset 0, where the
                        magic 7f 45 decodes as `jg +0x45` (taken: EFLAGS=0x202 at
                        entry) and lands on the code at 0x47. e_phnum/e_phentsize
                        sit inside p_memsz, which forces a ~4 GiB segment.

pause-*   the same layouts with syscall 34 (pause) instead of 60 (exit): the
          process blocks forever at zero CPU. As PID 1 it receives no SIGTERM
          without a handler, so `docker stop` waits out the grace period and
          SIGKILLs (exit 137), exactly like `sleep infinity`; `--init` fixes it.
pause-128-sigterm  0x2f layout plus rt_sigaction(SIGTERM) and a handler that
          exits 0, so `docker stop` returns at once. The 32-byte struct
          sigaction is overlaid on p_filesz (handler address), p_memsz
          (SA_RESTORER), p_align (restorer, never used) and the first 8 code
          bytes (signal mask), so it costs nothing beyond the 25 code bytes.

true-103/104/112 keep file bytes 4..19 canonical, which the binfmt_misc
magic/mask used by Docker Desktop (Rosetta) and qemu-user requires, and declare
p_filesz = p_memsz = 120 because Rosetta's loader asserts the first segment
spans both headers; the kernel zero-fills the rest of the page. true-80 and
true-75 only run on a native x86-64 Linux kernel.

Usage: python3 mktrue.py [outdir]   (default: out/)
"""
import os
import struct
import sys

BASE = 0x400000
EXIT0 = bytes.fromhex("b03c0f05")        # mov al,60 ; syscall
EXIT7 = bytes.fromhex("b03c40b7070f05")  # mov al,60 ; mov dil,7 ; syscall  (control)
PAUSE = bytes.fromhex("b0220f05")        # mov al,34 ; syscall              pause(), blocks forever
SA_RESTORER = 0x04000000
ROSETTA_MIN_SEG = 64 + 56                # Rosetta: segment_file_size >= ehdr + phdrs


def ehdr(entry, phoff, *, shoff=0, flags=0, ehsize=64, phnum=1, shentsize=0,
         shnum=0, shstrndx=0, e_type=2, version=1, ident_tail=b"\0" * 8):
    return (b"\x7fELF\x02\x01\x01\x00" + ident_tail +
            struct.pack("<HHIQQQIHHHHHH", e_type, 0x3e, version, entry, phoff, shoff,
                        flags, ehsize, 56, phnum, shentsize, shnum, shstrndx))


def phdr(*, ptype=1, flags=5, off=0, vaddr=BASE, paddr=0, filesz=0, memsz=0, align=0x1000):
    return struct.pack("<IIQQQQQQ", ptype, flags, off, vaddr, paddr, filesz, memsz, align)


def overlay(h, p, phoff):
    """ELF header h with program header p starting at phoff; overlapping bytes must agree."""
    n = 64 - phoff
    assert h[phoff:] == p[:n], f"phoff=0x{phoff:x}: overlapping bytes disagree"
    return h + p[n:]


def as_paddr(code):
    assert len(code) <= 8
    return int.from_bytes(code.ljust(8, b"\0"), "little")


def true_112(code):
    img = overlay(ehdr(BASE + 0x50, 0x38, shnum=5),
                  phdr(paddr=as_paddr(code), filesz=ROSETTA_MIN_SEG, memsz=ROSETTA_MIN_SEG), 0x38)
    assert img[0x50:0x50 + len(code)] == code and len(img) == 112
    return img


def true_104(code):
    img = overlay(ehdr(BASE + 0x48, 0x30, flags=1, ehsize=5),
                  phdr(flags=5 | 0x38 << 16, off=1, vaddr=BASE + 1, paddr=as_paddr(code),
                       filesz=ROSETTA_MIN_SEG, memsz=ROSETTA_MIN_SEG), 0x30)
    assert img[0x48:0x48 + len(code)] == code and len(img) == 104
    return img


def true_103(code):
    img = overlay(ehdr(BASE + 0x47, 0x2f, shoff=1 << 56, flags=0x05000000, ehsize=0),
                  phdr(flags=5 | 0x38 << 24, off=0x100, vaddr=BASE + 0x100, paddr=as_paddr(code),
                       filesz=ROSETTA_MIN_SEG, memsz=ROSETTA_MIN_SEG), 0x2f)
    assert img[0x47:0x47 + len(code)] == code and len(img) == 103
    return img


def true_80(code):
    assert len(code) <= 12
    seg = 0x500000000
    h = ehdr(seg + 1, 0x18, shoff=seg + 0x18, version=0, ident_tail=b"\0" * 8)
    h = h[:4] + code.ljust(12, b"\0") + h[16:]          # code in e_ident[4:16]
    img = overlay(h, phdr(off=0x18, vaddr=seg + 0x18, paddr=0x0038004000000000,
                          filesz=1, memsz=1), 0x18)
    assert len(img) == 80
    return img


def true_75(code=EXIT0):
    seg = 0x100380040                                   # forced by e_ehsize/e_phentsize/e_phnum
    h = ehdr(0xc << 32, 0x0c, shoff=0x00380040 << 32, flags=1, e_type=3, version=0x0c,
             ident_tail=b"\0" * 4 + struct.pack("<I", 1))
    img = overlay(h, phdr(flags=0x003e0003, off=0x0c, vaddr=(0xc << 32) | 0xc,
                          filesz=seg, memsz=seg, align=0), 0x0c)
    img = img.ljust(0x47, b"\0") + code
    assert len(img) == 0x47 + len(code)
    return img


def pause_sigterm():
    """pause() with a SIGTERM handler that exits 0; 0x2f layout; 128 bytes."""
    code_off = 0x67                                     # right after the program header
    code = bytes.fromhex(
        "b00d"        # mov al,13          rt_sigaction
        "40b70f"      # mov dil,15         SIGTERM
        "be4f004000"  # mov esi,0x40004f   &act = p_filesz field (file offset 0x4f)
        "41b208"      # mov r10b,8         sigsetsize
        "0f05"        # syscall            (rax = 0 on success)
        "b022" "0f05"  # mov al,34 ; syscall   pause(); never returns while the handler exits
        "b03c" "31ff" "0f05")  # handler: mov al,60 ; xor edi,edi ; syscall   exit(0)
    handler = BASE + code_off + code.index(bytes.fromhex("b03c31ff0f05"))
    h = ehdr(BASE + code_off, 0x2f, shoff=1 << 56, flags=0x05000000, ehsize=0)
    p = phdr(flags=5 | 0x38 << 24, off=0x100, vaddr=BASE + 0x100, paddr=0,
             filesz=handler, memsz=SA_RESTORER, align=0x1000)   # = sa_handler, sa_flags, sa_restorer
    img = overlay(h, p, 0x2f) + code                             # code[0:8] doubles as sa_mask
    assert len(img) == 128 and img[0x4f:0x57] == handler.to_bytes(8, "little")
    return img


VARIANTS = {
    "true-112": true_112(EXIT0), "true-112-exit7": true_112(EXIT7),
    "true-104": true_104(EXIT0), "true-104-exit7": true_104(EXIT7),
    "true-103": true_103(EXIT0), "true-103-exit7": true_103(EXIT7),
    "true-80":  true_80(EXIT0),  "true-80-exit7":  true_80(EXIT7),
    "true-75":  true_75(),
    "pause-112": true_112(PAUSE), "pause-104": true_104(PAUSE), "pause-103": true_103(PAUSE),
    "pause-80":  true_80(PAUSE),  "pause-75":  true_75(PAUSE),
    "pause-128-sigterm": pause_sigterm(),
}

if __name__ == "__main__":
    outdir = sys.argv[1] if len(sys.argv) > 1 else "out"
    os.makedirs(outdir, exist_ok=True)
    for name, img in VARIANTS.items():
        with open(os.path.join(outdir, name), "wb") as f:
            f.write(img)
        print(f"{name:16s} {len(img):4d} bytes")
