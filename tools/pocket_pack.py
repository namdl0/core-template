#!/usr/bin/env python3
"""
pocket_pack.py - packaging helper for the UFO 50 Analogue Pocket core.

Standard library only (Python 3.8+), works the same on Windows and Linux.

Sub-commands
------------
  reverse  IN.rbf OUT.rbf_r
      Bit-reverse every byte (Analogue: "for each byte, swap bits [7:0] to [0:7]").
      Quartus writes .rbf; the Pocket loads .rbf_r.

  validate
      Check dist/ against the limits in Analogue's core-definition docs
      (string lengths, slot counts, ids, file sizes of icon/platform image).

  package [--rbf PATH] [--out DIR] [--sd DRIVE_OR_DIR] [--allow-template-rbf]
      Build the SD-card tree and a release zip:
        build/sd/Cores/namdl0.UFO50/*.json, icon.bin, info.txt, bitstream.rbf_r
        build/sd/Platforms/ufo50.json, Platforms/_images/ufo50.bin
        build/<author>.<core>_<version>_<date>.zip   (Analogue's naming)
      With --sd, the same tree is also copied onto the SD card root
      (e.g. --sd E:\\ on Windows). Existing files are overwritten, nothing is
      deleted.

  image [--preview FILE.pgm]
      Regenerate dist/Platforms/_images/ufo50.bin (521x165 placeholder, plain
      text in a built-in 5x7 font; no game artwork).

  selftest
      Checks the bit reversal against the template's ap_core.rbf / bitstream.rbf_r
      pair if both are present, then runs validate.

Layout follows Analogue's "Packaging a Core" page and the dist/ convention used by
agg23's MIT-licensed cores (e.g. github.com/agg23/openfpga-pong: dist/Cores/<author>.<core>,
dist/Platforms, dist/Platforms/_images).
"""

import argparse
import hashlib
import json
import os
import shutil
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist")
DEFAULT_RBF = os.path.join(ROOT, "src", "fpga", "output_files", "ap_core.rbf")
BUILD = os.path.join(ROOT, "build")

# sha256 of src/fpga/output_files/ap_core.rbf as shipped in Analogue's core-template
# v1.3.0 (gray 320x240 screen). Packaging this by mistake means Quartus did not
# produce a new bitstream.
TEMPLATE_RBF_SHA256 = "7556b4ab134d84f44730a4d85817329e1492fbd7ad9b333014eff9b2195281ce"

REVERSE_TABLE = bytes(int("{:08b}".format(i)[::-1], 2) for i in range(256))

PLATFORM_IMG_W, PLATFORM_IMG_H = 521, 165
ICON_W = ICON_H = 36


# --------------------------------------------------------------------------- utils

def die(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(1)


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def as_int(v):
    if isinstance(v, int):
        return v
    if isinstance(v, str):
        return int(v, 0)
    raise ValueError("not an int or hex string: %r" % (v,))


def core_dir():
    cores = os.path.join(DIST, "Cores")
    dirs = [d for d in os.listdir(cores) if os.path.isdir(os.path.join(cores, d))]
    if len(dirs) != 1:
        die("expected exactly one folder in dist/Cores, found %r" % dirs)
    return os.path.join(cores, dirs[0])


def reverse_bits(data):
    return data.translate(REVERSE_TABLE)


# --------------------------------------------------------------------------- validate

def validate(verbose=True):
    errs = []

    def chk(cond, msg):
        if not cond:
            errs.append(msg)

    def maxlen(obj, key, n, where):
        if key in obj:
            chk(isinstance(obj[key], str) and len(obj[key]) <= n,
                "%s: '%s' must be a string of <= %d chars (got %r)" % (where, key, n, obj.get(key)))

    cdir = core_dir()
    folder = os.path.basename(cdir)

    # every JSON must parse and carry the magic
    for name in ("core", "data", "input", "interact", "variants", "video", "audio"):
        p = os.path.join(cdir, name + ".json")
        if not os.path.exists(p):
            errs.append("missing %s.json" % name)
            continue
        try:
            j = load_json(p)
        except ValueError as e:
            errs.append("%s.json: invalid JSON: %s" % (name, e))
            continue
        chk(j.get(name, {}).get("magic") == "APF_VER_1", "%s.json: magic must be APF_VER_1" % name)

    core = load_json(os.path.join(cdir, "core.json"))["core"]
    md = core["metadata"]
    maxlen(md, "shortname", 31, "core.json")
    maxlen(md, "description", 63, "core.json")
    maxlen(md, "author", 31, "core.json")
    maxlen(md, "url", 63, "core.json")
    maxlen(md, "version", 31, "core.json")
    maxlen(md, "date_release", 10, "core.json")
    chk(folder == "%s.%s" % (md["author"], md["shortname"]),
        "core folder '%s' must be '<author>.<shortname>' = '%s.%s'" % (folder, md["author"], md["shortname"]))
    chk(len(md["platform_ids"]) <= 4, "core.json: at most 4 platform_ids")
    fw = core["framework"]
    chk(fw.get("target_product") == "Analogue Pocket", "core.json: target_product must be 'Analogue Pocket'")
    chk(fw.get("dock", {}).get("supported") is True, "core.json: dock.supported must be true")
    chk(1 <= len(core["cores"]) <= 8, "core.json: 1..8 cores")
    for c in core["cores"]:
        maxlen(c, "name", 15, "core.json cores[]")
        maxlen(c, "filename", 15, "core.json cores[]")

    for pid in md["platform_ids"]:
        ok = (0 < len(pid) <= 15 and pid[0] != "_" and
              all(ch.islower() or ch.isdigit() or ch == "_" for ch in pid))
        chk(ok, "platform id '%s': lowercase/digits/_ only, <= 15 chars, not starting with _" % pid)
        pj = os.path.join(DIST, "Platforms", pid + ".json")
        if not os.path.exists(pj):
            errs.append("missing dist/Platforms/%s.json" % pid)
        else:
            pl = load_json(pj)["platform"]
            for k in ("category", "name", "manufacturer"):
                maxlen(pl, k, 31, "Platforms/%s.json" % pid)
            chk(isinstance(pl.get("year"), int), "Platforms/%s.json: year must be an integer" % pid)
        img = os.path.join(DIST, "Platforms", "_images", pid + ".bin")
        if os.path.exists(img):
            chk(os.path.getsize(img) == PLATFORM_IMG_W * PLATFORM_IMG_H * 2,
                "platform image %s must be %d bytes" % (img, PLATFORM_IMG_W * PLATFORM_IMG_H * 2))

    icon = os.path.join(cdir, "icon.bin")
    if os.path.exists(icon):
        chk(os.path.getsize(icon) == ICON_W * ICON_H * 2, "icon.bin must be %d bytes" % (ICON_W * ICON_H * 2))

    data = load_json(os.path.join(cdir, "data.json"))["data"]
    slots = data.get("data_slots", [])
    chk(len(slots) <= 32, "data.json: at most 32 slots")
    ids = set()
    for s in slots:
        where = "data.json slot '%s'" % s.get("name")
        maxlen(s, "name", 15, where)
        maxlen(s, "filename", 31, where)
        sid = as_int(s["id"])
        chk(0 <= sid <= 0xFFFF, where + ": id must be 16-bit")
        chk(sid not in ids, where + ": duplicate id %d" % sid)
        ids.add(sid)
        ext = s.get("extensions", [])
        chk(len(ext) <= 4 and all(len(e) <= 7 for e in ext), where + ": <= 4 extensions of <= 7 chars")
        for k in ("parameters", "size_exact", "size_maximum", "address"):
            if k in s:
                try:
                    v = as_int(s[k])
                    chk(0 <= v <= 0xFFFFFFFF, where + ": %s must be 32-bit" % k)
                except ValueError:
                    errs.append(where + ": %s is not an int/hex string" % k)
        if s.get("nonvolatile"):
            chk("size_maximum" in s or "size_exact" in s, where + ": nonvolatile slot should set size_maximum")

    inp = load_json(os.path.join(cdir, "input.json"))["input"]
    valid_keys = {"pad_btn_a", "pad_btn_b", "pad_btn_x", "pad_btn_y", "pad_trig_l",
                  "pad_trig_r", "pad_btn_start", "pad_btn_select"}
    chk(len(inp.get("controllers", [])) <= 4, "input.json: at most 4 controllers")
    for c in inp.get("controllers", []):
        mids = set()
        for m in c.get("mappings", []):
            chk(m.get("key") in valid_keys, "input.json: unknown key %r" % m.get("key"))
            maxlen(m, "name", 19, "input.json mapping")
            chk(m["id"] not in mids, "input.json: duplicate mapping id %r" % m["id"])
            mids.add(m["id"])

    vid = load_json(os.path.join(cdir, "video.json"))["video"]
    modes = vid.get("scaler_modes", [])
    chk(1 <= len(modes) <= 8, "video.json: 1..8 scaler_modes")
    for m in modes:
        chk(m.get("rotation", 0) in (0, 90, 180, 270), "video.json: rotation must be 0/90/180/270")
        chk(m["width"] > 0 and m["height"] > 0, "video.json: width/height must be > 0")

    if verbose:
        if errs:
            for e in errs:
                print("FAIL  " + e)
        else:
            print("validate: OK (%s, %d data slots, %d scaler mode(s))" % (folder, len(slots), len(modes)))
    return errs


# --------------------------------------------------------------------------- image

# 5x7 glyphs, '#' = ink
FONT = {
    "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
    "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
    "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
    " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
}


def render_placeholder():
    """Return a W x H list of rows, True = ink."""
    w, h = PLATFORM_IMG_W, PLATFORM_IMG_H
    img = [[False] * w for _ in range(h)]
    text = "UFO 50"
    scale = 12
    gw = 5 * scale
    gap = 2 * scale
    tw = len(text) * gw + (len(text) - 1) * gap
    x0 = (w - tw) // 2
    y0 = (h - 7 * scale) // 2 - 8
    for i, ch in enumerate(text):
        g = FONT[ch]
        for gy in range(7):
            for gx in range(5):
                if g[gy][gx] == "#":
                    for yy in range(scale):
                        for xx in range(scale):
                            img[y0 + gy * scale + yy][x0 + i * (gw + gap) + gx * scale + xx] = True
    # thin rule under the text
    ry = y0 + 7 * scale + 14
    for y in range(ry, ry + 4):
        for x in range(x0, x0 + tw):
            img[y][x] = True
    return img


def encode_pocket_image(img):
    """Pocket graphic format as used by the template's ex_platform.bin / icon.bin:
    16 bits per pixel, image rotated 90 degrees counter-clockwise (stored
    row-major as H columns x W rows), brightness byte first then 0x00.
    The template's background is 0xFF and its ink 0x00; this keeps that polarity."""
    h = len(img)
    w = len(img[0])
    out = bytearray()
    # rotate 90 CCW: new row r (0..w-1) = original column (w-1-r), read top to bottom
    for r in range(w):
        x = w - 1 - r
        for y in range(h):
            out += b"\x00\x00" if img[y][x] else b"\xff\x00"
    return bytes(out)


def cmd_image(args):
    img = render_placeholder()
    data = encode_pocket_image(img)
    pid = "ufo50"
    dst = os.path.join(DIST, "Platforms", "_images", pid + ".bin")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "wb") as f:
        f.write(data)
    print("wrote %s (%d bytes)" % (dst, len(data)))
    if args.preview:
        with open(args.preview, "wb") as f:
            f.write(b"P5\n%d %d\n255\n" % (PLATFORM_IMG_W, PLATFORM_IMG_H))
            for row in img:
                f.write(bytes(0 if p else 255 for p in row))
        print("wrote preview %s" % args.preview)


# --------------------------------------------------------------------------- reverse / package

def cmd_reverse(args):
    with open(args.inp, "rb") as f:
        data = f.read()
    with open(args.out, "wb") as f:
        f.write(reverse_bits(data))
    print("wrote %s (%d bytes)" % (args.out, len(data)))


def copytree_into(src, dst):
    for dirpath, _dirnames, filenames in os.walk(src):
        rel = os.path.relpath(dirpath, src)
        tdir = os.path.join(dst, rel) if rel != "." else dst
        os.makedirs(tdir, exist_ok=True)
        for fn in filenames:
            if fn in (".keep", ".gitkeep", ".DS_Store"):
                continue
            shutil.copy2(os.path.join(dirpath, fn), os.path.join(tdir, fn))


def cmd_package(args):
    errs = validate()
    if errs:
        die("dist/ failed validation, fix the errors above")

    rbf = args.rbf or DEFAULT_RBF
    if not os.path.exists(rbf):
        die("bitstream not found: %s (compile in Quartus first)" % rbf)
    with open(rbf, "rb") as f:
        rbf_data = f.read()
    digest = hashlib.sha256(rbf_data).hexdigest()
    if digest == TEMPLATE_RBF_SHA256 and not args.allow_template_rbf:
        die("%s is still the template's original bitstream (gray screen).\n"
            "       Compile the project in Quartus first, or pass --allow-template-rbf for an M0 test." % rbf)

    cdir = core_dir()
    folder = os.path.basename(cdir)
    md = load_json(os.path.join(cdir, "core.json"))["core"]["metadata"]
    core_files = load_json(os.path.join(cdir, "core.json"))["core"]["cores"]
    bit_name = core_files[0]["filename"]

    out = os.path.abspath(args.out or BUILD)
    sd = os.path.join(out, "sd")
    if os.path.isdir(sd):
        shutil.rmtree(sd)
    copytree_into(DIST, sd)
    with open(os.path.join(sd, "Cores", folder, bit_name), "wb") as f:
        f.write(reverse_bits(rbf_data))

    zname = "%s_%s_%s.zip" % (folder, md["version"], md["date_release"])
    zpath = os.path.join(out, zname)
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        for dirpath, _dirnames, filenames in os.walk(sd):
            for fn in sorted(filenames):
                full = os.path.join(dirpath, fn)
                z.write(full, os.path.relpath(full, sd).replace(os.sep, "/"))

    print("bitstream: %s (%d bytes, sha256 %s...)" % (rbf, len(rbf_data), digest[:16]))
    print("SD tree:   %s" % sd)
    print("zip:       %s" % zpath)
    with zipfile.ZipFile(zpath) as z:
        for n in z.namelist():
            print("   " + n)

    if args.sd:
        target = os.path.abspath(args.sd)
        if not os.path.isdir(target):
            die("SD path does not exist: %s" % target)
        copytree_into(sd, target)
        print("copied onto SD card at %s" % target)


def cmd_selftest(_args):
    ok = True
    t_rbf = os.path.join(ROOT, "src", "fpga", "output_files", "ap_core.rbf")
    t_rbfr = os.path.join(ROOT, "output", "bitstream.rbf_r")
    if os.path.exists(t_rbf) and os.path.exists(t_rbfr):
        a = open(t_rbf, "rb").read()
        b = open(t_rbfr, "rb").read()
        if hashlib.sha256(a).hexdigest() == TEMPLATE_RBF_SHA256:
            same = reverse_bits(a) == b
            print("reverse vs template pair: %s" % ("OK" if same else "MISMATCH"))
            ok = ok and same
        else:
            print("reverse vs template pair: skipped (ap_core.rbf is a new build)")
    assert reverse_bits(bytes([0x01, 0x80, 0xF0, 0xA5])) == bytes([0x80, 0x01, 0x0F, 0xA5])
    assert reverse_bits(reverse_bits(bytes(range(256)))) == bytes(range(256))
    ok = ok and not validate()
    print("selftest: %s" % ("OK" if ok else "FAILED"))
    sys.exit(0 if ok else 1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")

    p = sub.add_parser("reverse", help="bit-reverse .rbf -> .rbf_r")
    p.add_argument("inp")
    p.add_argument("out")
    p.set_defaults(func=cmd_reverse)

    p = sub.add_parser("validate", help="check dist/ against Analogue's documented limits")
    p.set_defaults(func=lambda a: sys.exit(1 if validate() else 0))

    p = sub.add_parser("package", help="build SD tree + release zip")
    p.add_argument("--rbf", help="Quartus .rbf (default src/fpga/output_files/ap_core.rbf)")
    p.add_argument("--out", help="output folder (default build/)")
    p.add_argument("--sd", help="also copy the tree onto this SD card root, e.g. E:\\")
    p.add_argument("--allow-template-rbf", action="store_true",
                   help="package even if the .rbf is the unmodified template bitstream")
    p.set_defaults(func=cmd_package)

    p = sub.add_parser("image", help="regenerate the placeholder platform image")
    p.add_argument("--preview", help="also write a .pgm preview")
    p.set_defaults(func=cmd_image)

    p = sub.add_parser("selftest", help="check bit reversal + validate")
    p.set_defaults(func=cmd_selftest)

    args = ap.parse_args()
    if not args.cmd:
        ap.print_help()
        sys.exit(2)
    args.func(args)


if __name__ == "__main__":
    main()
