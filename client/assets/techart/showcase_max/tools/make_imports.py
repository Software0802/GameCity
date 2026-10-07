#!/usr/bin/env python3
"""Write .import files for showcase_max textures so they import as mipmapped VRAM textures.

The headless importer would otherwise use the project defaults (lossless, no mipmaps), which
shimmers badly under a moving or oblique camera. Run, then `godot --headless --path . --import`.
"""
import glob
import os

HERE = os.path.dirname(os.path.abspath(__file__))
TEX = os.path.join(HERE, "..", "textures")
HDR = os.path.join(HERE, "..", "hdri")
RES = "res://client/assets/techart/showcase_max"

TEMPLATE = """[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="{src}"

[params]

compress/mode={mode}
compress/high_quality={hq}
compress/lossy_quality=0.8
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression={hdrc}
compress/normal_map={nm}
compress/channel_pack=0
mipmaps/generate={mips}
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=0
"""


def write(path, src, mode, hq, hdrc, nm, mips):
    if os.path.exists(path + ".import"):
        return  # keep the uid/path Godot already wrote
    with open(path + ".import", "w") as f:
        f.write(TEMPLATE.format(src=src, mode=mode, hq=str(hq).lower(), hdrc=hdrc, nm=nm, mips=str(mips).lower()))
    print("import:", os.path.basename(path))


def main():
    for p in sorted(glob.glob(os.path.join(TEX, "*.jpg"))):
        name = os.path.basename(p)
        nm = 1 if name.endswith("_nor.jpg") else 0
        write(p, "%s/textures/%s" % (RES, name), 2, True, 1, nm, True)
    for p in sorted(glob.glob(os.path.join(HDR, "*.hdr"))):
        name = os.path.basename(p)
        write(p, "%s/hdri/%s" % (RES, name), 0, False, 0, 0, False)


if __name__ == "__main__":
    main()
