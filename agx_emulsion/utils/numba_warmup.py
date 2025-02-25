from agx_emulsion.utils.fast_stats import warmup_fast_stats
from agx_emulsion.utils.lut3d import warmup_lut3d
from agx_emulsion.utils.fast_interp import warmup_fast_interp
from agx_emulsion.utils.fast_gaussian_filter import warmup_fast_gaussian_filter

# precompile numba functions
def warmup():
    warmup_fast_stats()
    warmup_lut3d()
    warmup_fast_interp()
    warmup_fast_gaussian_filter()
