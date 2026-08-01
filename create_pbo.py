#!/usr/bin/env python3
"""
PBO packer for Arma 3 - Based on Bohemia Interactive PBO File Format spec.

PBO binary layout:
  1. Vers entry (21 bytes): \0 + Vers(4) + 4 zero uint32s
  2. Properties (null-terminated key\\0value\\0 pairs, terminated by \\0)
  3. File entries (each: filename\\0 + 5 x uint32 = method, originalsize, reserved, timestamp, datasize)
  4. Sentinel entry (21 bytes: all zeros)
  5. Data block (file contents concatenated)
"""
import struct
import os
import sys
import time


def pack_pbo(source_dir, output_path, prefix=None):
    source_dir = os.path.abspath(source_dir)

    files = []
    for root, dirs, fnames in os.walk(source_dir):
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for fname in fnames:
            if fname.startswith('.') or fname.endswith('.pbo'):
                continue
            full_path = os.path.join(root, fname)
            rel_path = os.path.relpath(full_path, source_dir).replace('\\', '/')
            with open(full_path, 'rb') as f:
                data = f.read()
            files.append((rel_path, data))

    if not files:
        print("No files found to pack")
        return False

    files.sort(key=lambda x: x[0])
    now = int(time.time())

    # Read $PBOPREFIX$ if not provided
    if prefix is None:
        pboprefix_file = os.path.join(source_dir, '$PBOPREFIX$')
        if os.path.exists(pboprefix_file):
            with open(pboprefix_file, 'rb') as f:
                prefix = f.read().decode('utf-8', errors='replace').strip()
        else:
            prefix = ''

    with open(output_path, 'wb') as out:
        # 1. Vers entry (21 bytes): empty filename + Vers method + 4 zero uint32s
        out.write(b'\x00')                    # empty filename
        out.write(struct.pack('<I', 0x56657273))  # Vers method
        out.write(struct.pack('<I', 0))        # originalsize
        out.write(struct.pack('<I', 0))        # reserved
        out.write(struct.pack('<I', 0))        # timestamp
        out.write(struct.pack('<I', 0))        # datasize

        # 2. Properties (null-terminated key\0value\0 pairs)
        if prefix:
            out.write(b'prefix\x00')
            out.write(prefix.encode('utf-8'))
            out.write(b'\x00')
        out.write(b'\x00')  # end of properties

        # 3. File entries (each: filename\0 + 5 x uint32)
        for rel_path, data in files:
            name_bytes = rel_path.encode('utf-8') + b'\x00'
            out.write(name_bytes)
            out.write(struct.pack('<IIIII', 0, len(data), 0, now, len(data)))

        # 4. Sentinel entry (21 bytes: empty filename + 20 zero bytes)
        out.write(b'\x00' * 21)

        # 5. Data block (file contents in same order)
        for rel_path, data in files:
            out.write(data)

    print(f"PBO created: {output_path}")
    print(f"  Files: {len(files)}")
    print(f"  Size: {os.path.getsize(output_path)} bytes")
    return True


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <source_dir> <output.pbo> [prefix]")
        sys.exit(1)

    source = sys.argv[1]
    output = sys.argv[2]
    prefix_arg = sys.argv[3] if len(sys.argv) > 3 else None

    if not os.path.isdir(source):
        print(f"Error: Source directory '{source}' does not exist")
        sys.exit(1)

    os.makedirs(os.path.dirname(output) or '.', exist_ok=True)
    success = pack_pbo(source, output, prefix_arg)
    sys.exit(0 if success else 1)
