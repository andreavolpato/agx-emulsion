import numpy as np
from scipy.interpolate import interp1d, CubicSpline
from scipy.optimize import least_squares

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

def measure_density_min(log_exposure, density_curves, info_type):
    
    dc = density_curves
    le = log_exposure
    density_min = np.zeros(3)
    
    # fitting model for the toe
    def curve_toe(e, k):
        gamma = k[0]
        e0    = k[1]
        d0    = k[2]
        c1    = k[3] 
        y = (  gamma/c1 * np.log10(1 + 10**(c1 * (e - e0) ) ) 
            ) + d0
        return y
    
    # starting parameters of fit
    if info_type=='positive':
        k0 = (-1, 0, 0.05, -2)
    else:
        k0 = (1, 0, 0.05, 2)
    
    # fit all the toes and save density min
    for i in np.arange(3):
        data = np.copy(dc[:,i])
        # mask data above the toe (1/5 of density range)
        data[data>((np.nanmax(data)-np.nanmin(data))/5+np.nanmin(data))] = np.nan
        def residues(k):
            res = data - curve_toe(le, k)
            res = np.nan_to_num(res)
            return res
        fit = least_squares(residues, k0)
        k = fit.x
        density_min[i] = k[2]
    return density_min