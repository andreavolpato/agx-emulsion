"""Load the *shipping* engine through ctypes.

RFC-014 §2.1 lists this as one of the three reasons the boundary is a C ABI
rather than Swift's C++ interop: the same `.h` drives Swift, the C++ tests, and
Python. So the numba parity oracle points at the binary that ships instead of
at a reimplementation of it -- which is the difference between measuring the
port and measuring a copy of the port.
"""
from __future__ import annotations

import ctypes
import json
import os
from pathlib import Path

import numpy as np

ENGINE = Path(__file__).resolve().parents[1]

SPK_OK = 0


class SpkImage(ctypes.Structure):
    _fields_ = [
        ("data", ctypes.POINTER(ctypes.c_float)),
        ("width", ctypes.c_uint32),
        ("height", ctypes.c_uint32),
        ("channels", ctypes.c_uint32),
    ]


class SpkResult(ctypes.Structure):
    _fields_ = [
        ("rgba16", ctypes.POINTER(ctypes.c_uint16)),
        ("texture", ctypes.c_void_p),
        ("width", ctypes.c_uint32),
        ("height", ctypes.c_uint32),
        ("row_stride_px", ctypes.c_uint32),
        ("elapsed_ms", ctypes.c_double),
        ("reprint", ctypes.c_int32),
        ("negative_was_cached", ctypes.c_int32),
        ("progress_id", ctypes.c_char * 40),
    ]


class EngineError(RuntimeError):
    pass


class Engine:
    def __init__(self, dylib: Path | None = None, resources: Path | None = None):
        self._lib = ctypes.CDLL(str(dylib or ENGINE / "build" / "libspektrafilm_engine.dylib"))
        self._declare()
        # `SPEKTRAFILM_ENGINE_RESOURCES` is the same override `EngineClient`
        # honours first, and it is here for the same reason: it is what lets a
        # harness be pointed at the resources *inside a built .app* rather
        # than at the checkout's. That is the only way to check that what
        # shipped is what was tested -- `engine/build.sh bundle` is an rsync,
        # and an rsync that did not run leaves a stale bundle rather than an
        # empty one.
        env = os.environ.get("SPEKTRAFILM_ENGINE_RESOURCES")
        self._resources = str(resources or env or ENGINE / "resources")
        self._handle = self._lib.spk_engine_create(self._resources.encode(), None)
        if not self._handle:
            raise EngineError(self._last_error())

    def _declare(self) -> None:
        lib = self._lib
        lib.spk_engine_create.restype = ctypes.c_void_p
        lib.spk_engine_create.argtypes = [ctypes.c_char_p, ctypes.c_void_p]
        lib.spk_engine_destroy.argtypes = [ctypes.c_void_p]
        lib.spk_capabilities.restype = ctypes.c_char_p
        lib.spk_capabilities.argtypes = [ctypes.c_void_p]
        lib.spk_params_schema.restype = ctypes.c_char_p
        lib.spk_params_schema.argtypes = [ctypes.c_void_p]
        lib.spk_last_error.restype = ctypes.c_char_p
        lib.spk_last_error.argtypes = [ctypes.c_void_p]
        lib.spk_build_info.restype = ctypes.c_char_p
        lib.spk_warm_up.restype = ctypes.c_int32
        lib.spk_warm_up.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p,
                                    ctypes.POINTER(ctypes.c_char_p)]
        lib.spk_open.restype = ctypes.c_void_p
        lib.spk_open.argtypes = [ctypes.c_void_p, ctypes.POINTER(SpkImage), ctypes.c_char_p,
                                 ctypes.POINTER(ctypes.c_char_p)]
        lib.spk_set_params.restype = ctypes.c_int32
        lib.spk_set_params.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                       ctypes.POINTER(ctypes.c_char_p)]
        lib.spk_get_params.restype = ctypes.c_int32
        lib.spk_get_params.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p)]
        lib.spk_solve.restype = ctypes.c_int32
        lib.spk_solve.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_char_p)]
        for name in ("spk_reprint", "spk_render"):
            fn = getattr(lib, name)
            fn.restype = ctypes.c_int32
            fn.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(SpkResult)]
        lib.spk_print_lut_catalog.restype = ctypes.c_char_p
        lib.spk_print_lut_catalog.argtypes = [ctypes.c_void_p]
        lib.spk_print_lut_table.restype = ctypes.c_int32
        lib.spk_print_lut_table.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                            ctypes.POINTER(ctypes.POINTER(ctypes.c_float)),
                                            ctypes.POINTER(ctypes.c_uint32)]
        lib.spk_preview_stock_lut.restype = ctypes.c_int32
        lib.spk_preview_stock_lut.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p,
                                              ctypes.POINTER(SpkResult),
                                              ctypes.POINTER(ctypes.c_char_p)]
        lib.spk_export_di.restype = ctypes.c_int32
        lib.spk_export_di.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                      ctypes.POINTER(SpkResult),
                                      ctypes.POINTER(ctypes.c_char_p)]
        lib.spk_progress.restype = ctypes.c_int32
        lib.spk_progress.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_char_p)]
        lib.spk_session_release.argtypes = [ctypes.c_void_p]
        lib.spk_result_free.argtypes = [ctypes.POINTER(SpkResult)]
        lib.spk_string_free.argtypes = [ctypes.c_char_p]

    def _last_error(self) -> str:
        return (self._lib.spk_last_error(self._handle) or b"").decode()

    def _take_json(self, buf: ctypes.c_char_p) -> dict:
        if not buf:
            return {}
        text = ctypes.cast(buf, ctypes.c_char_p).value or b"{}"
        parsed = json.loads(text)
        self._lib.spk_string_free(buf)
        return parsed

    # --- the method surface, one to one with the C ABI -------------------

    @property
    def build_info(self) -> str:
        return self._lib.spk_build_info().decode()

    def capabilities(self) -> dict:
        return json.loads(self._lib.spk_capabilities(self._handle).decode())

    def params_schema(self) -> dict:
        return json.loads(self._lib.spk_params_schema(self._handle).decode())

    def warm_up(self, film: str, print_stock: str) -> dict:
        out = ctypes.c_char_p()
        if self._lib.spk_warm_up(self._handle, film.encode(), print_stock.encode(),
                                 ctypes.byref(out)) != SPK_OK:
            raise EngineError(self._last_error())
        return self._take_json(out)

    def print_lut_catalog(self) -> dict:
        return json.loads((self._lib.spk_print_lut_catalog(self._handle) or b"{}").decode())

    def print_lut_table(self, stock: str) -> np.ndarray:
        """The (S, S, S, 3) float32 table, engine-owned -- copied out here.

        The pointer stays valid for the engine's lifetime, but a harness that
        held it across `close()` would be reading freed memory, so this copies
        rather than wrapping.
        """
        table = ctypes.POINTER(ctypes.c_float)()
        size = ctypes.c_uint32()
        if self._lib.spk_print_lut_table(self._handle, stock.encode(), ctypes.byref(table),
                                         ctypes.byref(size)) != SPK_OK:
            raise EngineError(self._last_error())
        n = size.value ** 3 * 3
        flat = np.ctypeslib.as_array(table, shape=(n,))
        return np.array(flat.reshape(size.value, size.value, size.value, 3), copy=True)

    def open(self, image: np.ndarray, delta: dict | None = None) -> "Session":
        array = np.ascontiguousarray(np.asarray(image, dtype=np.float32))
        if array.ndim != 3 or array.shape[2] not in (3, 4):
            raise ValueError(f"expected (H, W, 3 or 4), got {array.shape}")
        spk_image = SpkImage(array.ctypes.data_as(ctypes.POINTER(ctypes.c_float)),
                             array.shape[1], array.shape[0], array.shape[2])
        out = ctypes.c_char_p()
        handle = self._lib.spk_open(self._handle, ctypes.byref(spk_image),
                                    json.dumps(delta or {}).encode(), ctypes.byref(out))
        if not handle:
            raise EngineError(self._last_error())
        return Session(self, handle, self._take_json(out), array)

    def close(self) -> None:
        if self._handle:
            self._lib.spk_engine_destroy(self._handle)
            self._handle = None

    def __enter__(self): return self
    def __exit__(self, *exc): self.close()


class Session:
    def __init__(self, engine: Engine, handle, reply: dict, keepalive: np.ndarray):
        self._engine = engine
        self._handle = handle
        self.reply = reply
        # `spk_open` copies the pixels, but keeping the array alive costs
        # nothing and removes a class of use-after-free from the harness.
        self._keepalive = keepalive

    def set_params(self, delta: dict) -> dict:
        out = ctypes.c_char_p()
        if self._engine._lib.spk_set_params(self._handle, json.dumps(delta).encode(),
                                            ctypes.byref(out)) != SPK_OK:
            raise EngineError(self._engine._last_error())
        return self._engine._take_json(out)

    def get_params(self) -> dict:
        out = ctypes.c_char_p()
        if self._engine._lib.spk_get_params(self._handle, ctypes.byref(out)) != SPK_OK:
            raise EngineError(self._engine._last_error())
        return self._engine._take_json(out)

    def solve(self, target: str = "both") -> dict:
        out = ctypes.c_char_p()
        if self._engine._lib.spk_solve(self._handle, target.encode(), ctypes.byref(out)) != SPK_OK:
            raise EngineError(self._engine._last_error())
        return self._engine._take_json(out)

    def render(self, tier: str = "live", reprint: bool = False) -> tuple[np.ndarray, SpkResult]:
        result = SpkResult()
        fn = self._engine._lib.spk_reprint if reprint else self._engine._lib.spk_render
        if fn(self._handle, tier.encode(), ctypes.byref(result)) != SPK_OK:
            raise EngineError(self._engine._last_error())
        # The rows are texture-aligned so the canvas can draw them in place;
        # the harness reads the packed pixels back out of the padded buffer,
        # using the stride the engine reports rather than re-deriving it.
        h, w, stride = result.height, result.width, result.row_stride_px
        flat = np.ctypeslib.as_array(result.rgba16, shape=(h * stride * 4,))
        rgba = np.array(flat.reshape(h, stride, 4)[:, :w, :], copy=True)
        # The texture is handed over +1 and its buffer is what `rgba16` points
        # into, so the copy above has to happen before this. Swift's ARC does
        # this release; a ctypes caller has to say it, and not saying it leaks
        # a full-tier buffer per render.
        self._engine._lib.spk_result_free(ctypes.byref(result))
        return rgba, result

    def _take_result(self, result: SpkResult) -> np.ndarray:
        h, w, stride = result.height, result.width, result.row_stride_px
        flat = np.ctypeslib.as_array(result.rgba16, shape=(h * stride * 4,))
        rgba = np.array(flat.reshape(h, stride, 4)[:, :w, :], copy=True)
        self._engine._lib.spk_result_free(ctypes.byref(result))
        return rgba

    def preview_stock_lut(self, print_stock: str, tier: str = "live") -> tuple[np.ndarray, dict]:
        result, out = SpkResult(), ctypes.c_char_p()
        if self._engine._lib.spk_preview_stock_lut(self._handle, print_stock.encode(),
                                                   tier.encode(), ctypes.byref(result),
                                                   ctypes.byref(out)) != SPK_OK:
            raise EngineError(self._engine._last_error())
        return self._take_result(result), self._engine._take_json(out)

    def export_di(self, print_stock: str | None = None) -> tuple[np.ndarray, dict]:
        result, out = SpkResult(), ctypes.c_char_p()
        if self._engine._lib.spk_export_di(self._handle,
                                           print_stock.encode() if print_stock else None,
                                           ctypes.byref(result), ctypes.byref(out)) != SPK_OK:
            raise EngineError(self._engine._last_error())
        return self._take_result(result), self._engine._take_json(out)

    def progress(self) -> dict:
        out = ctypes.c_char_p()
        if self._engine._lib.spk_progress(self._handle, None, ctypes.byref(out)) != SPK_OK:
            raise EngineError(self._engine._last_error())
        return self._engine._take_json(out)

    def close(self) -> None:
        if self._handle:
            self._engine._lib.spk_session_release(self._handle)
            self._handle = None

    def __enter__(self): return self
    def __exit__(self, *exc): self.close()
