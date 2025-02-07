import numpy as np
from agx_emulsion.profiles.io import load_profile
from agx_emulsion.model.illuminants import standard_illuminant

p = load_profile('kodak_portra_400_au')
ill = standard_illuminant(type='D55')
s = 10**np.double(p.data.log_sensitivity)
print(np.nansum(ill[:,None]*s, axis=0))