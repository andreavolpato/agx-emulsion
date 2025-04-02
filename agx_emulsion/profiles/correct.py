import numpy as np
import scipy.interpolate
import copy
from agx_emulsion.model.process import photo_process, photo_params
from agx_emulsion.model.stocks import fit_print_filters

def measure_log_exposure_midscale_neutral(profile, reference_channel=None):
    log_exposure_midscale_neutral = np.zeros((3,))
    d_mid = profile.info.density_midscale_neutral
    if np.size(d_mid)==1: 
        d_mid = np.ones(3) * d_mid
    if reference_channel=='green':
        d_mid = np.ones(3) * d_mid[1]
    for i in range(3):
        if profile.info.type=='positive':
            log_exposure_midscale_neutral[i] = np.interp(-d_mid[i], -profile.data.density_curves[:,i], profile.data.log_exposure)
        else:
            log_exposure_midscale_neutral[i] = np.interp(d_mid[i], profile.data.density_curves[:,i], profile.data.log_exposure)
    print('Log exposure midscale neutral:', log_exposure_midscale_neutral)
    return log_exposure_midscale_neutral

def align_midscale_neutral_exposures(profile, reference_channel=None):
    log_exposure_midscale_neutral = measure_log_exposure_midscale_neutral(profile, reference_channel)
    dc = profile.data.density_curves
    le = profile.data.log_exposure
    for i in np.arange(3):
            dc[:,i] = np.interp(le, le-log_exposure_midscale_neutral[i], dc[:,i])
    profile.data.density_curves = dc
    profile.info.log_exposure_midscale_neutral = (np.ones(3)*log_exposure_midscale_neutral[1]).tolist()
    return profile

############################################################################################################
# fit gray strip

def correct_negative_curves_with_gray_ramp(negative_profile,
                                           target_paper='kodak_portra_endura_uc',
                                           data_trustability=0.5, # control the bias of the fit, 1.0 smallest correction, 0.0 largest correction
                                           stretch_curves=False,
                                           ):
    # get the parameters
    pl = photo_params(print_paper=target_paper, ymc_filters_from_database=False)
    pl.negative = copy.deepcopy(negative_profile)
    pl.settings.rgb_to_raw_method = 'mallett2019'
    fit_print_filters(pl)
    
    density_scale, shift_corr, stretch_corr = fit_corrections_from_grey_ramp(pl, data_trustability, stretch_curves)
    print('Density scale corr:', density_scale)
    print('Shift corr:', shift_corr)
    print('Stretch corr:', stretch_corr)
    profile_corrected = apply_scale_shift_stretch_density_curves(pl.negative, density_scale, shift_corr, stretch_corr)
    return profile_corrected

def fit_corrections_from_grey_ramp(p0, data_trustability=1.0, stretch_curves=False):
    midgray_rgb = np.array([0.184, 0.184, 0.184])
    def residues(x):
        if stretch_curves:  gray, reference = gray_ramp(p0, density_scale=x[0:3], shift_corr=[x[3],0,x[4]], stretch_corr=x[5:8])
        else:               gray, reference = gray_ramp(p0, density_scale=x[0:3], shift_corr=[x[3],0,x[4]])
        res = np.array(gray) - reference
        res = res.flatten()
          
        
        bias_scale = 2.0*(np.array(x[0:3])-1)
        if stretch_curves:
            bias_stretch = 100.0*(np.array(x[6:9])-1)
            bias = np.concatenate((bias_scale, bias_stretch))
        else: bias = bias_scale
        
        res = np.concatenate((res, bias*data_trustability))
        return res
    if stretch_curves:  x0 = [1., 1., 1.,  0., 0.,  1., 1., 1.]
    else:               x0 = [1., 1., 1.,  0., 0.]
    fit = scipy.optimize.least_squares(residues, x0)
    density_scale = fit.x[0:3]
    shift_corr = [fit.x[3], 0, fit.x[4]]
    if stretch_curves: stretch_corr = fit.x[5:8]
    else:              stretch_corr = [1,1,1]
    return density_scale, shift_corr, stretch_corr

def gray_ramp(p0, density_scale=[1,1,1], shift_corr=[0,0,0], stretch_corr=[1,1,1]):
    pl = copy.copy(p0)
    pl.io.input_cctf_decoding = False
    pl.io.input_color_space = 'sRGB'
    pl.debug.deactivate_spatial_effects = True
    pl.debug.deactivate_stochastic_effects = True
    pl.print_paper.glare.active = False
    pl.io.output_cctf_encoding = False
    pl.settings.rgb_to_raw_method = 'mallett2019'
    pl.negative = apply_scale_shift_stretch_density_curves(pl.negative, density_scale, shift_corr, stretch_corr)
    midgray_rgb = np.array([[[0.184,0.184,0.184]]])
    # gradient = (2**np.linspace(-2,2,5))[None,:,None]
    # reference = midgray_rgb*gradient
    ev_ramp = [-2,-1,0,1,2,3,4,5,6]
    gray = np.zeros((np.size(ev_ramp),3))
    for i in np.arange(np.size(ev_ramp)):
        pl.camera.exposure_compensation_ev = ev_ramp[i]
        gray[i] = photo_process(midgray_rgb, pl).flatten()
    return gray, midgray_rgb

def apply_scale_shift_stretch_density_curves(profile, density_scale=[1,1,1], log_exposure_shift=[0,0,0], log_exposure_strech=[1,1,1]):
    dc = copy.copy(profile.data.density_curves)
    le = copy.copy(profile.data.log_exposure)
    dc = dc * density_scale
    for i in np.arange(3):
        dc[:,i] = np.interp(le, le/log_exposure_strech[i]+log_exposure_shift[i], dc[:,i])
    profile.data.density_curves = dc
    return profile

########################################################################################

def heavy_lifting_density_curves(profile, 
                                 density_max=False,
                                 log_exposure=False,
                                 gamma=False,
                                 gamma_correction_range_ev=2
                                 ):
    # density max corrections makes all channels have the same density max equal to the mean of the three
    # log exposure corrections uses midscale neutral density (equal for all channels) and shifts density curves
    # gamma corrections align slopes at log exposure of midscale neutral to the green channel one
    if density_max:
        profile = normalize_density_max(profile)
    if log_exposure:
        profile = align_midscale_neutral_exposures(profile)
    if gamma:
        gamma, le_ref = measure_slopes(profile, log_exposure_range=np.log10(2**gamma_correction_range_ev))
        mean_gamma = np.mean(gamma)
        slope_correction = gamma/mean_gamma
        profile = apply_gamma_correction(profile, 1/slope_correction, le_ref)
    return profile


def measure_slopes(profile, log_exposure_range=np.log10(2**2)):
    le_ref = measure_log_exposure_midscale_neutral(profile)
    log_exposure_0 = le_ref - log_exposure_range/2
    log_exposure_1 = le_ref + log_exposure_range/2
    density_curves = profile.data.density_curves
    log_exposure = profile.data.log_exposure
    gamma = np.zeros((3,))
    for i in range(3):
        sel = ~np.isnan(density_curves[:,i])
        density_1 = scipy.interpolate.CubicSpline(log_exposure[sel], density_curves[sel,i])(log_exposure_1[i])
        density_0 = scipy.interpolate.CubicSpline(log_exposure[sel], density_curves[sel,i])(log_exposure_0[i])
        gamma[i] = (density_1-density_0)/(log_exposure_1[i]-log_exposure_0[i])
    print('Gamma:',gamma)
    return gamma, le_ref

def apply_gamma_correction(profile, gamma_correction, log_exposure_reference=[0.,0.,0.]):
    le_ref = log_exposure_reference
    dc = profile.data.density_curves
    le = profile.data.log_exposure
    gc = np.array(gamma_correction)
    dc_out = np.zeros_like(dc)
    for i in np.arange(3):
        dc_out[:,i] = np.interp(le, (le-le_ref[i])/gc[i] + le_ref[i], dc[:,i])
    profile.data.density_curves = dc_out
    return profile

def normalize_density_max(profile):
    dmax = np.nanmax(profile.data.density_curves,axis=0)
    dmax_mean = np.mean(dmax)
    print('Density max:',dmax)
    profile.data.density_curves *= dmax_mean/dmax
    print('Setting density max of all channels to:',dmax_mean)
    return profile
    

# slopes = meausre_slope(le, dc, log_exposure_0=log_exposure_midscale_neutral[1]-0.2, log_exposure_1=log_exposure_midscale_neutral[i]+0)


if __name__=='__main__':
    from agx_emulsion.profiles.factory import load_profile, plot_profile, adjust_log_exposure
    import matplotlib.pyplot as plt

    # profile = load_profile('fujifilm_pro_400h_au')
    profile = load_profile('kodak_vision3_50d_u')
    plot_profile(profile)
    
    profile_hv = heavy_lifting_density_curves(profile, density_max=True, log_exposure=True, gamma=True)
    plot_profile(profile_hv)
    profile_corrected = correct_negative_curves_with_gray_ramp(profile,
                                                               target_paper='kodak_portra_endura_uc',
                                                               data_trustability=0.3,
                                                               stretch_curves=False)
    profile_corrected = adjust_log_exposure(profile_corrected)
    plot_profile(profile_corrected)
    plt.show()