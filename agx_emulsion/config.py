import numpy as np
import colour

# Constants
ENLARGER_STEPS = 170
LOG_EXPOSURE = np.linspace(-3,4,256)
SPECTRAL_SHAPE = colour.SpectralShape(380, 780, 5)

# Default color matching functions
STANDARD_OBSERVER_CMFS = colour.MSDS_CMFS["CIE 1931 2 Degree Standard Observer"].copy().align(SPECTRAL_SHAPE)