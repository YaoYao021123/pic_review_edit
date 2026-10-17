# Converts the Image-Adaptive-3DLUT weights (Apache-2.0) for Lucet without PyTorch.
"""Reads legacy (pre-1.6, non-zip) PyTorch .pth files without torch.

Only tensor-rebuild records are accepted; any other class in the pickle is refused, so loading
cannot run code from the file."""
import collections, io, json, pickle, struct, sys

class Storage:
    def __init__(self, dtype, key, count):
        self.dtype, self.key, self.count, self.data = dtype, key, count, None

class Tensor:
    def __init__(self, storage, offset, size, stride):
        self.storage, self.offset, self.size, self.stride = storage, offset, tuple(size), tuple(stride)
    def values(self):
        # Contiguous row-major tensors only (what state_dicts hold).
        n = 1
        for s in self.size: n *= s
        expected, acc = [], 1
        for s in reversed(self.size): expected.insert(0, acc); acc *= s
        assert tuple(expected) == self.stride or n <= 1, (self.size, self.stride)
        return self.storage.data[self.offset:self.offset + n]

DTYPES = {"FloatStorage": "f", "LongStorage": "q", "IntStorage": "i", "DoubleStorage": "d"}

def rebuild_tensor_v2(storage, offset, size, stride, requires_grad=False, hooks=None, *rest):
    return Tensor(storage, offset, size, stride)

def rebuild_parameter(tensor, requires_grad=False, hooks=None):
    return tensor

class Safe(pickle.Unpickler):
    def __init__(self, f, storages):
        super().__init__(f); self.storages = storages
    def find_class(self, module, name):
        if (module, name) == ("torch._utils", "_rebuild_tensor_v2"): return rebuild_tensor_v2
        if (module, name) == ("torch._utils", "_rebuild_parameter"): return rebuild_parameter
        if (module, name) == ("collections", "OrderedDict"): return collections.OrderedDict
        if module == "torch" and name in DTYPES: return name
        raise pickle.UnpicklingError(f"refused: {module}.{name}")
    def persistent_load(self, pid):
        kind, dtype, key, location, count = pid[:5]
        assert kind == "storage" and dtype in DTYPES, pid
        if key not in self.storages: self.storages[key] = Storage(dtype, key, count)
        return self.storages[key]

class Plain(pickle.Unpickler):
    def find_class(self, module, name): raise pickle.UnpicklingError(f"refused: {module}.{name}")

def load(path):
    with open(path, "rb") as f:
        raw = f.read()
    f = io.BytesIO(raw)
    magic = Plain(f).load(); protocol = Plain(f).load(); Plain(f).load()  # sys info
    assert magic == 0x1950a86a20f9469cfc6c and protocol == 1001, (magic, protocol)
    storages = {}
    result = Safe(f, storages).load()
    keys = Plain(f).load()
    for key in keys:
        s = storages[key]
        count = struct.unpack("<q", f.read(8))[0]
        assert count == s.count, (key, count, s.count)
        width = struct.calcsize(DTYPES[s.dtype])
        s.data = list(struct.unpack("<%d%s" % (count, DTYPES[s.dtype]), f.read(width * count)))
    assert f.read() == b"", "trailing data"
    return result

# --- Conversion -------------------------------------------------------------------------
# Usage: python3 -I scripts/convert-adaptive-lut.py <folder with classifier.pth and LUTs.pth> <out.bin>
# Output: "A3DL", uint32 version (1), uint32 tensor count, then for each tensor a uint32 element
# count and that many little-endian float32 values, in the order of ORDER below.
ORDER = [f"model.{i}.{p}" for i in (1, 3, 4, 6, 7, 9, 10, 12, 13, 16) for p in ("weight", "bias")]
SHAPES = {"model.1.weight": (16, 3, 3, 3), "model.4.weight": (32, 16, 3, 3), "model.7.weight": (64, 32, 3, 3),
          "model.10.weight": (128, 64, 3, 3), "model.13.weight": (128, 128, 3, 3), "model.16.weight": (3, 128, 8, 8)}

def convert(folder, out):
    import hashlib, os
    classifier = load(os.path.join(folder, "classifier.pth"))
    luts = load(os.path.join(folder, "LUTs.pth"))
    tensors = []
    for name in ORDER:
        t = classifier[name]
        if name in SHAPES: assert t.size == SHAPES[name], (name, t.size)
        tensors.append(t.values())
    for i in range(3):
        t = luts[str(i)]["LUT"]
        assert t.size == (3, 33, 33, 33), t.size  # [channel][blue][green][red]
        tensors.append(t.values())
    with open(out, "wb") as f:
        f.write(b"A3DL" + struct.pack("<II", 1, len(tensors)))
        for values in tensors:
            f.write(struct.pack("<I", len(values)) + struct.pack("<%df" % len(values), *values))
    for name in ("classifier.pth", "LUTs.pth"):
        with open(os.path.join(folder, name), "rb") as f: print(name, hashlib.sha256(f.read()).hexdigest())
    with open(out, "rb") as f: print(os.path.basename(out), hashlib.sha256(f.read()).hexdigest())

if __name__ == "__main__":
    convert(sys.argv[1], sys.argv[2])
