# true

[![ci](https://github.com/sholdee/true/actions/workflows/ci.yml/badge.svg)](https://github.com/sholdee/true/actions/workflows/ci.yml)

The smallest `FROM scratch` container image that does nothing and exits 0,
built from hand-laid-out x86-64 ELF binaries of 75 to 112 bytes.

A static ELF64 needs a 64-byte ELF header, one 56-byte program header and the
4-byte program `mov al,60 ; syscall`, so the obvious floor is 124 bytes. The
binaries here start the program header *inside* the ELF header so that each of
its fields lands on an ELF-header field the loader never reads. See the
docstring in [`mktrue.py`](mktrue.py) for the field-by-field layouts.

| binary     | bytes | native x86-64 Linux | Docker Desktop (arm64 host, Rosetta) | notes |
|------------|------:|:-------------------:|:------------------------------------:|-------|
| `true-112` |   112 | ✅ | ✅ | only `e_shnum` is off |
| `true-104` |   104 | ✅ | ✅ | `e_ehsize` = 5 |
| `true-103` |   103 | ✅ | ✅ | smallest that passes binfmt_misc + Rosetta |
| `true-80`  |    80 | ✅ | ❌ exec format error | code in `e_ident`; ET_EXEC |
| `true-75`  |    75 | ✅ | ❌ exec format error | ET_DYN, enters on the magic (`jg`); forces a ~4 GiB `p_memsz` |

Each size also has a `-exit7` control (same layout, exits 7) so CI proves the
exit status comes from the embedded code rather than from a loader shortcut.

## Why 103 on Docker Desktop

On an Apple Silicon host, Docker Desktop hands amd64 binaries to Rosetta via
binfmt_misc, whose registration matches file bytes 0..19 against a mask. That
pins the ident, `e_type` and `e_machine` bytes, so the program header cannot
start before offset 0x2f. Rosetta's loader additionally asserts
`p_filesz >= sizeof(Ehdr) + sizeof(Phdr)`, which the Rosetta-safe variants
satisfy by declaring a 120-byte segment; Linux zero-fills past end of file
within the page.

## Usage

```sh
python3 mktrue.py                 # writes out/true-*
./test.sh native                  # on an x86-64 Linux host
./test.sh docker                  # builds FROM scratch images and runs them
docker build --build-arg BIN=true-103 -t true .
docker run --rm true; echo $?     # 0
```

CI runs both test modes on an x86-64 `ubuntu-latest` runner on every push.

## Caveats

- `readelf`/`objdump` complain about every variant; the kernel does not.
- `true-75` maps about 4 GiB of address space because `e_phnum` and
  `e_phentsize` sit inside `p_memsz`; it segfaults under a 2 GB `ulimit -v`.
- Image size barely changes: tar pads each entry to 512-byte blocks.

## References

- Brian Raiter, [A Whirlwind Tutorial on Creating Really Teensy ELF Executables for Linux](https://www.muppetlabs.com/~breadbox/software/tiny/teensy.html)
- Nathan Otterness, [Tiny ELF Files: Revisited in 2021](https://nathanotterness.com/2021/10/tiny_elf_modernized.html)
