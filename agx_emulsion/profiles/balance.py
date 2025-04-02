import numpy as np
import scipy
import colour

from colour.models import RGB_COLOURSPACE_sRGB
from agx_emulsion.config import STANDARD_OBSERVER_CMFS

from agx_emulsion.model.illuminants import standard_illuminant

def balance_sensitivity(profile, correct_log_exposure=True):
    ls = profile.data.log_sensitivity
    le = profile.data.log_exposure
    dc = profile.data.density_curves
    ill = standard_illuminant(type=profile.info.reference_illuminant)
    s = 10**np.double(ls)
    neutral_exposures = np.nansum(ill[:,None]*s, axis=0)
    corr = neutral_exposures[1]/neutral_exposures
    print('--- Balance Sensitivity')
    print('Correction factors for sensitivity:', corr)
    log_exp_correction = np.log10(corr)
    print('Log exposure correction of density curves:', log_exp_correction)
    
    s *= corr
    ls = np.log10(s)
    profile.data.log_sensitivity = ls
    
    if correct_log_exposure:
        dc_out = np.zeros_like(dc)
        for i in np.arange(3):
            dc_out[:,i] = np.interp(le, le+log_exp_correction[i], dc[:,i])
        profile.data.density_curves = dc_out
    
    return profile


def balance_density(profile):
    """Use green desnity at zero log expsoure and shift the others on top"""
    density_curves = profile.data.density_curves
    le = profile.data.log_exposure

    density_0 = np.interp(0, le, density_curves[:,1])
    print('--- Balance Density')
    print('Density at zero green channel:',density_0)
    le_shift_m = np.interp(density_0, density_curves[:,0], le)
    le_shift_y = np.interp(density_0, density_curves[:,2], le)
    density_curves[:,0] = np.interp(le, le-le_shift_m, density_curves[:,0])
    density_curves[:,2] = np.interp(le, le-le_shift_y, density_curves[:,2])
    le_shift = [le_shift_m, 0, le_shift_y]
    print('Log exposure shifts:', le_shift)
    profile.data.log_sensitivity -= le_shift
    profile.data.density_curves = density_curves
    return profile

def balance_metameric_neutral(profile, midgray_value=0.184):
    illuminant = standard_illuminant(profile.info.viewing_illuminant)

    def rgb_mid(mid, illuminant=illuminant):
        light = 10**(-mid)*illuminant[:]   
        light[np.isnan(light)] = 0
        
        normalization = np.sum(illuminant * STANDARD_OBSERVER_CMFS[:, 1], axis=0)
        xyz = np.einsum('k,kl->l', light, STANDARD_OBSERVER_CMFS[:]) / normalization
        illuminant_xyz = np.einsum('k,kl->l', illuminant, STANDARD_OBSERVER_CMFS[:]) / normalization 
        illuminant_xy = colour.XYZ_to_xy(illuminant_xyz)
        rgb = colour.XYZ_to_RGB(xyz, RGB_COLOURSPACE_sRGB, apply_cctf_encoding=False, illuminant=illuminant_xy)
        return rgb

    def midscale_neutral(density_cmy, dye_density=profile.data.dye_density):
        mid = np.sum(dye_density[:,:3] * density_cmy, axis=1) + dye_density[:,3]
        return mid
    
    transmittance_0 = midgray_value
    # density_0 = np.log10(1/transmittance_0)
    # density_0 += np.nanmean(profile.data.dye_density[:,3])
    # transmittance_0 = 10**(-density_0)
    rgb_0 = np.ones(3)*transmittance_0

    def residues(params):
        mid = midscale_neutral(density_cmy=params)
        rgb = rgb_mid(mid)
        res = rgb_0 - rgb
        return res
    
    fit = scipy.optimize.least_squares(residues, [1.0, 1.0, 1.0])
    d_cmy_metameric = fit.x
    profile.info.density_midscale_neutral = d_cmy_metameric[1]
    d_cmy_scale = d_cmy_metameric / d_cmy_metameric[1]
    mid = midscale_neutral(d_cmy_metameric)
    # rgb = rgb_mid(mid, viewing_illuminant=p.info.viewing_illuminant)
    print('--- Balance Metameric Neutral')
    print('Density CMY of metameric neutral: ', d_cmy_metameric)
    print('Apllied density scale factors: ', d_cmy_scale)
    profile.data.dye_density[:,4] = mid
    profile.data.dye_density[:, :3] *= d_cmy_scale
    return profile
