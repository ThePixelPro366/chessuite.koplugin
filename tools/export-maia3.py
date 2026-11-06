#!/usr/bin/env python3
"""
Converts the Maia3 5M checkpoint (https://huggingface.co/UofTCSSLab/Maia3-5M)
into the flat half-precision weight file read by tools/maia3/maia3.c.

    curl -LO https://huggingface.co/UofTCSSLab/Maia3-5M/resolve/main/maia3-5m.pt
    python3 tools/export-maia3.py maia3-5m.pt bin/maia3-5m.bin

Needs torch (the checkpoint is only read with weights_only=True) and numpy.
The layout must match load_weights() in maia3.c.
"""
import struct
import sys

import numpy as np
import torch

DIM, HEADS, BLOCKS, MLP, EMB, GEN, GAB_HID, HEAD_HID, TOK = 256, 8, 8, 512, 128, 64, 64, 256, 96


def main(src, dst):
    ck = torch.load(src, map_location="cpu", weights_only=True)
    sd = ck.get("model_state_dict", ck)
    sd = {k.replace("smolgen", "gab"): v.float().numpy() for k, v in sd.items()}

    shared = sd["gab_shared_weight"]
    for i in range(BLOCKS):
        w = sd.get(f"transformer.layers.{i}.self_attn.gab_weight")
        if w is not None and not np.array_equal(w, shared):
            sys.exit(f"layer {i} has its own GAB weight; this converter expects a shared one")

    order = [
        ("elo_embedding_low.weight", (1, EMB)),
        ("elo_embedding_high.weight", (1, EMB)),
        ("token_projection.weight", (DIM, TOK + 2 * EMB)),
        ("token_projection.bias", (DIM,)),
        ("gab_shared_weight", (64 * 64, GEN)),
    ]
    for i in range(BLOCKS):
        p = f"transformer.layers.{i}."
        order += [
            (p + "self_attn.mha.in_proj_weight", (3 * DIM, DIM)),
            (p + "self_attn.mha.out_proj.weight", (DIM, DIM)),
            (p + "self_attn.sm2.weight", (GAB_HID, DIM)),
            (p + "self_attn.sm2.bias", (GAB_HID,)),
            (p + "self_attn.ln1.weight", (GAB_HID,)),
            (p + "self_attn.ln1.bias", (GAB_HID,)),
            (p + "self_attn.sm3.weight", (HEADS * GEN, GAB_HID)),
            (p + "self_attn.sm3.bias", (HEADS * GEN,)),
            (p + "self_attn.ln2.weight", (HEADS * GEN,)),
            (p + "self_attn.ln2.bias", (HEADS * GEN,)),
            (p + "linear1.weight", (MLP, DIM)),
            (p + "linear1.bias", (MLP,)),
            (p + "linear2.weight", (DIM, MLP)),
            (p + "linear2.bias", (DIM,)),
            (p + "norm1.weight", (DIM,)),
            (p + "norm2.weight", (DIM,)),
        ]
    order += [
        ("transformer.norm.weight", (DIM,)),
        ("transformer.norm.bias", (DIM,)),
        ("proj_sq_from.weight", (HEAD_HID, DIM)),
        ("proj_sq_to.weight", (HEAD_HID, DIM)),
        ("promo_bias_proj.weight", (4, HEAD_HID)),
        ("last_ln.weight", (DIM,)),
        ("last_ln.bias", (DIM,)),
        ("fc_value_hid.weight", (HEAD_HID, DIM)),
        ("fc_value_hid.bias", (HEAD_HID,)),
        ("fc_value.weight", (3, HEAD_HID)),
        ("fc_value.bias", (3,)),
    ]

    with open(dst, "wb") as f:
        f.write(b"MAIA3W01")
        f.write(struct.pack("<9i", DIM, HEADS, BLOCKS, MLP, EMB, GEN, GAB_HID, HEAD_HID, TOK))
        count = 0
        for name, shape in order:
            a = sd[name]
            if a.shape != shape:
                sys.exit(f"{name}: expected {shape}, got {a.shape}")
            f.write(a.astype("<f2").tobytes())
            count += a.size
    print(f"wrote {dst}: {count} weights")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
