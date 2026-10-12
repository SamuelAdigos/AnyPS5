import struct, sys

def unself(src, dst):
    d = open(src, 'rb').read()
    magic = d[:4]
    if magic not in (bytes.fromhex('4f153d1d'), bytes.fromhex('5414f5ee')):
        raise SystemExit(f'{src}: not a SELF ({magic.hex()})')
    num_entries = struct.unpack_from('<H', d, 0x18)[0]
    entries = [struct.unpack_from('<QQQQ', d, 0x20 + i * 0x20) for i in range(num_entries)]
    eh = 0x20 + num_entries * 0x20
    if d[eh:eh + 4] != b'\x7fELF':
        raise SystemExit(f'{src}: no ELF header at {eh:#x}')
    e_phoff, = struct.unpack_from('<Q', d, eh + 0x20)
    e_phentsize, e_phnum = struct.unpack_from('<HH', d, eh + 0x36)
    phdrs = [struct.unpack_from('<IIQQQQQQ', d, eh + e_phoff + i * e_phentsize) for i in range(e_phnum)]
    size = max([p[2] + p[5] for p in phdrs if p[5]] + [e_phoff + e_phnum * e_phentsize])
    out = bytearray(size)
    out[:e_phoff + e_phnum * e_phentsize] = d[eh:eh + e_phoff + e_phnum * e_phentsize]
    struct.pack_into('<Q', out, 0x28, 0)
    struct.pack_into('<HH', out, 0x3c, 0, 0)
    copied = 0
    for props, off, filesz, memsz in entries:
        if not props & 0x800:
            continue
        if props & 0x2 or props & 0x8:
            raise SystemExit(f'{src}: encrypted or compressed segment (props {props:#x})')
        idx = (props >> 20) & 0xfff
        p = phdrs[idx]
        out[p[2]:p[2] + filesz] = d[off:off + filesz]
        copied += 1
    open(dst, 'wb').write(out)
    print(f'{src} -> {dst}: {e_phnum} phdrs, {copied} segments, {len(out)} bytes')

for a in sys.argv[1:]:
    s, t = a.split(':')
    unself(s, t)
