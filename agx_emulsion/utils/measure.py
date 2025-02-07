import numpy as np
from scipy.interpolate import interp1d, CubicSpline

def measure_gamma(log_exposure, density_curves, density_0=0.25, density_1=1.0):
    gamma = np.zeros((3,))
    for i in range(3):
        loge0 = interp1d(density_curves[:, i], log_exposure, kind='cubic')(density_0)
        loge1 = interp1d(density_curves[:, i], log_exposure, kind='cubic')(density_1)
        gamma[i] = (density_1-density_0)/(loge1-loge0)
    return gamma

def measure_slopes_at_exposure(log_exposure, density_curves, 
                               log_exposure_reference=0.0,
                               log_exposure_range=np.log10(2**2)):
    le_ref = log_exposure_reference
    log_exposure_0 = le_ref - log_exposure_range/2
    log_exposure_1 = le_ref + log_exposure_range/2
    gamma = np.zeros((3,))
    for i in range(3):
        sel = ~np.isnan(density_curves[:,i])
        density_1 = CubicSpline(log_exposure[sel], density_curves[sel,i])(log_exposure_1)
        density_0 = CubicSpline(log_exposure[sel], density_curves[sel,i])(log_exposure_0)
        gamma[i] = (density_1-density_0)/(log_exposure_1-log_exposure_0)
    return gamma