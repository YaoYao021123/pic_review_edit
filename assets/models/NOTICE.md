# adaptive-lut.bin

The weights behind **AI Look** (AI 调色): Image-Adaptive-3DLUT by Hui Zeng, Jianrui Cai, Lida Li,
Zisheng Cao and Lei Zhang, "Learning Image-adaptive 3D Lookup Tables for High Performance Photo
Enhancement in Real-time", IEEE TPAMI 2020.

- Source: https://github.com/HuiZeng/Image-Adaptive-3DLUT, `pretrained_models/sRGB/` (trained on the
  MIT-Adobe FiveK sRGB set)
- License: Apache License 2.0, https://www.apache.org/licenses/LICENSE-2.0
- Original files (SHA-256):
  - `classifier.pth` bae9865395625ecae58cfe86147e521093bb1e29e7b2544e02adb238b8035021
  - `LUTs.pth` c1bb2bc4b7239c1a7e96159f5923123ba796b1fceb0b8c3132b423ea825b821a
- Converted, values unchanged, by `scripts/convert-adaptive-lut.py` (no PyTorch needed):
  `adaptive-lut.bin` 1f1e76766ccf1e9f43f443e9b930e79bb6b6fe55cc6c85a712ee1a2e481917c4

Layout: `A3DL`, version 1, 23 tensors (each a uint32 count and float32 values, little-endian): the
classifier's five 3 × 3 convolutions with their instance norms, the final 8 × 8 convolution, then
the three 33³ basis LUTs as [channel][blue][green][red]. The network runs in
`Sources/MediaCore/AdaptiveLUT.swift`; a test checks it against an independent forward pass.
