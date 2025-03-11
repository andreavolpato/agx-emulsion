import numpy as np
import scipy
import copy
from dotmap import DotMap
import matplotlib.pyplot as plt

from agx_emulsion.profiles.reconstruct import reconstruct_dye_density
from agx_emulsion.profiles.balance import balance_sensitivity, balance_metameric_neutral
from agx_emulsion.profiles.correct import align_midscale_neutral_exposures

from agx_emulsion.model.density_curves import fit_density_curve, compute_density_curves, compute_density_curves_layers
from agx_emulsion.utils.io import load_agx_emulsion_data, load_densitometer_data
from agx_emulsion.profiles.io import load_profile

################################################################################
# Fittings
################################################################################

def find_midscale_neutral_coefficients(dye_density, fit=True):
    mid_over_base = dye_density[:,4] - dye_density[:,3]
    
    if fit:
        sel = np.all(~np.isnan(dye_density), axis=1)
        def residues_midscale_neutral_dye_density(x):
            res = mid_over_base - np.nansum(dye_density[:,0:3]*x, axis=1)
            res = res[sel]
            return res
        fit = scipy.optimize.least_squares(residues_midscale_neutral_dye_density, [1,1,1])
        x = fit.x
    else:
        # find the max of dye density and compute at that wavelength mid_over_base
        dd_max = np.nanmax(dye_density[:,:3], axis=0)
        index_max = np.nanargmax(dye_density[:,:3], axis=0)
        d_mid = np.zeros(3)
        for i, imax in enumerate(index_max):
            d_mid[i] = np.interp(imax, np.arange(np.size(mid_over_base)), mid_over_base)
        x = d_mid / dd_max
    return x

def fit_density_curves(log_exposure,
                       density,
                       model='norm_cdfs',
                       type='negative'):
    fitted_parameters = np.zeros((3,9))
    for i in np.arange(3):
        fitted_parameters[i] = fit_density_curve(log_exposure, density[:,i],
                                                 type, model=model)
    return fitted_parameters

################################################################################
# Unmix densities
################################################################################

def compute_densitometer_crosstalk_matrix(densitometer_intensity, dye_density):
    crosstalk_matrix = np.zeros((3,3))
    dye_transmittance = 10**(-dye_density[:,0:3])
    for i in np.arange(3): # rgb of densitometer
        for j in np.arange(3): # cmy of dyes
            crosstalk_matrix[i,j] = -np.log10(
                np.nansum(densitometer_intensity[:,i]*dye_transmittance[:,j])
                / np.nansum(densitometer_intensity[:,i])
                )
    return crosstalk_matrix

def unmix_density_curves(curves, crosstalk_matrix):
    inverse_cm = np.linalg.inv(crosstalk_matrix)
    density_curves_raw = np.einsum('ij, kj-> ki',inverse_cm, curves)
    density_curves_raw = np.clip(density_curves_raw,0,None)
    return density_curves_raw

################################################################################
# Unmix sensitivities
################################################################################

def fit_log_scaled_absortion_coefficients(sensitivity, crosstalk_matrix, density_curves, log_exposure,
                          density_level=0.2, log_exposure_reference_sensitivity=0):
    sensitivity[sensitivity==0] = np.nan
    sensitivity_log_exposures = np.log10( 1/sensitivity ) # sensitivity exposure
    # if data not available because not enough sensitivity, set a very high log exposure value necessary to reach the target density level
    sensitivity_log_exposures[np.isnan(sensitivity_log_exposures)] = np.nanmax(sensitivity_log_exposures) + 6
    
    def unmixed_densities_at_a_sensitivity_log_exposure(log_absorption_coefficients_rgb, sensitivity_log_exposure_i):
        unmixed_densities = np.zeros(3)
        for i in np.arange(3):
            # even if the apparent absorption coefficient i am fitting is not the real one it is good to add an amount of light (log_exposure_reference_sensitivity)
            # that is making the absortption coefficient become numerically similar to the sensitivity, in this way the fitting is more stable.
            # We can think of the absorption coefficient times a factor that makes the exposure compatible with the unmixed density curves.
            log_exposure_with_new_reference = log_exposure_reference_sensitivity + sensitivity_log_exposure_i
            unmixed_densities[i] = np.interp(log_exposure_with_new_reference + log_absorption_coefficients_rgb[i],
                             log_exposure, density_curves[:,i])
        if np.isnan(sensitivity_log_exposure_i):
            unmixed_densities = np.nan(3)
        return unmixed_densities
    # each RGB layer has a certain absorption coefficient at a certain wavelength.
    # the three possible data points of sensitivity at a certain wavelength are three experiments a three different exposures.
    # in every experiment the absorption coefficients are the same, because the properties of the layer are unchanged.
    # in every experiment the exposure is at the level to reach the density_level, e.g. 0.2, at the denstitometer, i.e. with crosstalk.
    # we can fit a set of three absorption coefficients for each wavelength, able to reproduce the three RGB densitometer densities.
    
    def densitometer_densities_at_sensitivity_log_exposures(log_absorption_coefficients_rgb, sensitivity_log_exposures):
        densitometer_densitiy = np.zeros(3)
        for i in np.arange(3):
            # Let's focus to a certain densitometer channel (R, G, or B), that has a certain log_exposure that is absorbed in the three layers.
            unmixed_densities = unmixed_densities_at_a_sensitivity_log_exposure(log_absorption_coefficients_rgb,
                                                                          sensitivity_log_exposures[i])
            densitometer_densitiy[i] = np.sum(crosstalk_matrix[i,:] * unmixed_densities)
        return densitometer_densitiy
    
    target = np.array([density_level, density_level, density_level])
    log_absorption_coefficients = np.zeros(sensitivity_log_exposures.shape)
    log_absorption_coefficients_0 = np.log10(sensitivity)
    log_absorption_coefficients_0[np.isnan(log_absorption_coefficients_0)] = np.nanmin(log_absorption_coefficients_0)-6
    for i in np.arange(sensitivity_log_exposures.shape[0]):
        def residues(log_absorption_coefficients_rgb):
            res = target - densitometer_densities_at_sensitivity_log_exposures(log_absorption_coefficients_rgb, sensitivity_log_exposures[i,:])
            return res
        fit = scipy.optimize.least_squares(residues, log_absorption_coefficients_0[i,:], method='lm')
        log_absorption_coefficients[i,:] = fit.x
    
    log_absorption_coefficients[np.isnan(sensitivity)] = np.nan
    return log_absorption_coefficients

def find_log_exposure_reference(log_exposure, density_curves, density_reference=1.0, decreasing_density=False):
    sel = np.all(~np.isnan(density_curves), axis=1)
    log_exposure_reference = 0
    if decreasing_density:
        sign = -1
    else:
        sign = 1
    for i in np.arange(3):
        log_exposure_reference += np.interp(sign*density_reference,
                                            sign*density_curves[sel,i], log_exposure[sel])
    log_exposure_reference /= 3 # TODO: think if the mean is the correct choice or if I should keep the reference for each channel
    return log_exposure_reference

def unmix_sensitivity(profile, control_plot=False):
    print('----------------------------------------')
    print('# Unmixing Sensitivity - assumes unmixed densities')
    print(profile.info.stock,' - ',profile.info.type)

    log_sensitivity = profile.data.log_sensitivity
    density_curves = profile.data.density_curves
    dye_density = profile.data.dye_density
    log_exposure = profile.data.log_exposure
    wavelengths = profile.data.wavelengths
    type = profile.info.type
    sensitivity_density_level = profile.info.log_sensitivity_density_over_min
    sensitivity = 10**log_sensitivity

    # cross talk matrix
    dr = load_densitometer_data(type=profile.info.densitometer)
    densitometer_crosstalk_matrix = compute_densitometer_crosstalk_matrix(dr, dye_density[:,0:3])
    density_curves_densitometer_minus_dmin = np.einsum('ij,kj->ki', densitometer_crosstalk_matrix, density_curves)

    log_sensitivity_prefit = np.copy(log_sensitivity)
    # unmix sensitivity
    log_exposure_reference_sensitivity = find_log_exposure_reference(log_exposure,
                                                           density_curves_densitometer_minus_dmin,
                                                           sensitivity_density_level,
                                                           decreasing_density=type=='positive')
    print('Log-exposure reference for sensitivity: ', log_exposure_reference_sensitivity)
    # log_exposure_sensitivity is not really necessary but good in order to get final 1/exposure=sensitivity unmixed close to the originals
    log_absorption_coefficients = fit_log_scaled_absortion_coefficients(sensitivity,
                                                            densitometer_crosstalk_matrix,
                                                            density_curves,
                                                            log_exposure,
                                                            sensitivity_density_level,
                                                            log_exposure_reference_sensitivity)

    # save sensitivity
    print(log_absorption_coefficients.shape)
    profile.data.log_sensitivity = log_absorption_coefficients
    
    if control_plot:
        _, ax = plt.subplots()
        ax.plot(wavelengths, log_absorption_coefficients, color='k')
        ax.plot(wavelengths, log_sensitivity_prefit, color='gray', linestyle='--')
        ax.legend(('r','g','b'))
        ax.set_title('Sensitivity unmix')
        ax.set_xlabel('Wavelength (nm)')
        ax.set_ylabel('Log Sensitivity')
        ax.set_title(profile.info.stock)

    return profile

################################################################################
# Create profile
################################################################################

def create_profile(stock='kodak_portra_400',
                   type='negative', # negative, positive, or paper
                   color=True,
                   name=None,
                   densitometer='status_M', # status_A or status_M
                   log_sensitivity_density_over_min=0.2,
                   log_sensitivity_donor=None,
                   denisty_curves_donor=None,
                   dye_density_cmy_donor=None,
                   dye_density_min_mid_donor=None,
                   reference_illuminant='D55',
                   viewing_illuminant='D50',
                   ):
    ls, d, wl, c, le = load_agx_emulsion_data(stock=stock,
                                              log_sensitivity_donor=log_sensitivity_donor,
                                              denisty_curves_donor=denisty_curves_donor,
                                              dye_density_cmy_donor=dye_density_cmy_donor,
                                              dye_density_min_mid_donor=dye_density_min_mid_donor,
                                              type=type,
                                              color=color,
                                              )
    print(stock,' - ',type)
    
    profile = {}
    profile = DotMap()
    profile.info.stock = stock
    if name is None:
        profile.info.name = stock
    else:
        profile.info.name = name
    profile.info.type = type
    profile.info.color = color
    profile.info.densitometer = densitometer
    profile.info.log_sensitivity_density_over_min = log_sensitivity_density_over_min
    profile.info.reference_illuminant = reference_illuminant
    profile.info.viewing_illuminant = viewing_illuminant
    
    profile.data.log_sensitivity = ls
    profile.data.wavelengths = wl    
    profile.data.density_curves = c
    profile.data.log_exposure = le
    profile.data.dye_density = d
    profile.data.tune.gamma_factor = 1.0
    profile.data.tune.dye_density_min_factor = 1.0
    # profile.data.tune.gamma_correction = [1.0,1.0,1.0] # affects colors when comparing different exposures
    # profile.data.tune.log_exposure_correction = [0.0,0.0,0.0] # affects color of underexposed areas
    profile.data.density_curves_layers = np.array((0,3,3))
    
    # profile.parametric.density_curves.active = False
    # profile.parametric.density_curves.gamma = [0.7,0.7,0.7]
    # profile.parametric.density_curves.log_exposure_0 = [-1.4,-1.4,-1.52]
    # profile.parametric.density_curves.density_max = [2.75,2.75,2.84]
    # profile.parametric.density_curves.toe_size = [0.3,0.3,0.3]
    # profile.parametric.density_curves.shoulder_size = [0.85,0.85,0.85]
    
    profile.glare.active = False
    profile.glare.percent = 0.0
    profile.glare.roughness = 0.25
    profile.glare.blur = 0.5
    
    if type == 'negative':
        profile.grain.active = True
        profile.grain.sublayers_active = True
        profile.grain.agx_particle_area_um2 = 0.2 # approx 200 iso
        profile.grain.agx_particle_scale = [0.8,1,2]
        profile.grain.agx_particle_scale_layers = [2.5,1,0.5]
        profile.grain.density_min = [0.07, 0.08, 0.12]
        profile.grain.uniformity = [0.97,0.97,0.99]
        profile.grain.blur = 0.55
        profile.grain.blur_dye_clouds_um = 1.0
        profile.grain.micro_structure = (0.2, 0.5)
        profile.grain.n_sub_layers = 1
        
        profile.halation.active = True
        profile.halation.strength = [0.08,0.005,0.001]
        profile.halation.size_um = [200,200,200]
        profile.halation.scattering_strength = [0.01,0.02,0.04]
        profile.halation.scattering_size_um = [30,20,15]

        profile.dir_couplers.active = True
        profile.dir_couplers.amount = 1.0
        profile.dir_couplers.ratio_rgb = (1.0,1.0,1.0)
        profile.dir_couplers.diffusion_interlayer = 2.0
        profile.dir_couplers.diffusion_size_um = 10.0
        profile.dir_couplers.high_exposure_shift = 0.0 # increase saturation and contrast with overexposure
        
        profile.masking_couplers.cross_over_points = [585, 510, 200]
        profile.masking_couplers.transition_widths = [ 15,  15,   1]
        profile.masking_couplers.gaussian_model = [ [[435, 20, 0.09], [560, 20, 0.09]],
                                                    [[470, 20, 0.09]                 ], 
                                                    [[520, 20, 0.09]                 ] ] # [wl, width, amount]
    
    if type == 'paper':       
        profile.glare.active = True
        profile.glare.percent = 0.1
        profile.glare.roughness = 0.4
        profile.glare.blur = 0.5
        profile.glare.compensation_removal_factor = 0.0
        profile.glare.compensation_removal_density = 1.2
        profile.glare.compensation_removal_transition = 0.3
        
        profile.data.tune.dye_density_min_factor = 0.4

        
    return profile

def remove_density_min(profile):
    
    dc = profile.data.density_curves
    dd = profile.data.dye_density
    wl = profile.data.wavelengths
    type = profile.info.type

    # take care of density min
    dc_min = np.nanmin(dc, axis=0)
    dc = dc - dc_min
    print('Density curve min values:', dc_min)
    
    # if positive or paper, add b+f to the dye_density min and mid
    if type=='paper' or type=='positive':
        status_a_max_peak = [445, 530, 610] # nm, plus two far values for extrapolation
        smin = np.interp(wl, status_a_max_peak, dc_min)
        sigma = 20 # nm
        sigma_points = sigma / np.mean(np.diff(wl))
        smin = scipy.ndimage.gaussian_filter1d(smin, sigma_points)
        dd[:,3] = smin

    # save dye_density
    profile.data.dye_density = dd
    profile.data.density_curves = dc
    return profile

def adjust_log_exposure(profile,
                        speed_point_density=0.2,
                        stops_over_speed_point=3,
                        midgray_transmittance=0.184
                        ):
    if profile.info.type=='paper' or profile.info.type=='positive':
        speed_point_density = np.log10(1/midgray_transmittance)
        stops_over_speed_point = 0
    
    # use the green channel to find the speed point log_exposure
    # then add stops_over_speed_point to the speed point log_exposure
    # finally assign to that log_exposure zero value
    print('Reference density:', speed_point_density)
    print('Stops over reference density:', stops_over_speed_point, 'EV')
    dcg = profile.data.density_curves[:,1]
    dcg = dcg - np.nanmin(dcg)
    le = profile.data.log_exposure
    sel = ~np.isnan(dcg)
    if profile.info.type=='negative' or profile.info.type=='paper':
        le_speed_point = np.interp(speed_point_density, dcg[sel], le[sel])
    if profile.info.type=='positive':
        le_speed_point = np.interp(-speed_point_density, -dcg[sel], le[sel])
    print('Log exposure refenrece:', le_speed_point)
    le_over_speed_point = np.log10(2**stops_over_speed_point)
    le_midgray = le_speed_point + le_over_speed_point
    le -= le_midgray
    profile.data.log_exposure = le
    return profile

def apply_masking_couplers(profile, control_plot=True, effectiveness=1.0, model='erf'):
    dd = profile.data.dye_density
    base = profile.data.dye_density[:,3]
    wl = profile.data.wavelengths
    
    if model == 'erf':
        cross_over_points = profile.masking_couplers.cross_over_points
        transition_widths = profile.masking_couplers.transition_widths
        
        wl_scaled = (wl[:,None]-cross_over_points)/transition_widths
        
        coupler_mask_spectral = (scipy.special.erf(wl_scaled) + 1 + effectiveness)/(2+effectiveness)
        ddcmy = copy.copy(dd[:,0:3])
        
        dd_w_couplers = ddcmy * coupler_mask_spectral
        profile.data.dye_density[:,0:3] = dd_w_couplers
    
    if model == 'gaussians':
        # p_couplers = [[ [wl, width, amount] ]] first index is channel, second is peak, third [wl, width, amount]
        p_couplers = profile.masking_couplers.gaussian_model 
        def spectral_profiles(wl, parameters):
            density = np.zeros((np.size(wl), 3))
            for i in np.arange(3):
                for ps in parameters[i]:
                    density[:,i] += ps[2] * np.exp( -(wl-ps[0])**2/(2*ps[1]**2) )
            return density
        coupler_mask_spectral_subtractive = spectral_profiles(wl, p_couplers)
        ddcmy = copy.copy(dd[:,0:3])
        dd_w_couplers = ddcmy - coupler_mask_spectral_subtractive*effectiveness
        profile.data.dye_density[:,0:3] = dd_w_couplers    
    
    if control_plot:
        # fit dye density midscale coefficient as a check, not used elsewhere
        dye_density_midscale_coefficients = find_midscale_neutral_coefficients(dd) # reference is red
        print('midscale_coefficients: ',dye_density_midscale_coefficients)
        mid_sim = dd_w_couplers * dye_density_midscale_coefficients
        mid_sim = np.sum(mid_sim, axis=1) + base
        
        fig, ax = plt.subplots()
        ax.plot(wl, ddcmy[:,0], color='tab:cyan')
        ax.plot(wl, ddcmy[:,1], color='tab:pink')
        ax.plot(wl, ddcmy[:,2], color='gold')
        ax.plot(wl, dd_w_couplers[:,0], color='tab:cyan', linestyle='--', label='_nolegend_')
        ax.plot(wl, dd_w_couplers[:,1], color='tab:pink', linestyle='--', label='_nolegend_')
        ax.plot(wl, dd_w_couplers[:,2], color='gold', linestyle='--', label='_nolegend_')
        ax.plot(wl, base, color='gray', linewidth=1)
        ax.plot(wl, dd[:,4], color='lightgray', linewidth=1)
        ax.plot(wl, mid_sim, color='gray', linestyle='--', linewidth=1)
        ax.legend(('C','M','Y','Min','Mid','Sim'))
        ax.set_xlabel('Wavelength (nm)')
        ax.set_ylabel('Diffuse Density')
        ax.set_xlim((350, 750))
        ax.set_title('Masking Couplers Effects to Dye Density')
    return profile

def rescale_dye_density_using_neutral(profile):
    dd = profile.data.dye_density
    dye_density_midscale_coefficients = find_midscale_neutral_coefficients(dd)
    dye_density_midscale_coefficients /= dye_density_midscale_coefficients[1] # normalize to green
    dd[:,0:3] *= dye_density_midscale_coefficients
    profile.data.dye_density = dd
    return  profile

def unmix_density(profile):
    dc = profile.data.density_curves
    dd = profile.data.dye_density
    # dd = dd / np.nanmax(dd, axis=0)
    
    # cross talk matrix
    ds = load_densitometer_data(type=profile.info.densitometer)
    densitometer_crosstalk_matrix = compute_densitometer_crosstalk_matrix(ds, dd[:,0:3])
    print('densitometer C: ')
    print(densitometer_crosstalk_matrix)
    
    dc = unmix_density_curves(dc, densitometer_crosstalk_matrix)
    
    # dc[dc<0] = 0 # HERE
    profile.data.density_curves = dc
    return profile

def densitometer_normalization(profile):
    dc = profile.data.density_curves
    dd = profile.data.dye_density
    dstm = load_densitometer_data(type=profile.info.densitometer)
    
    M = compute_densitometer_crosstalk_matrix(dstm, dd)
    norm_coeffs = np.diag(M)
    print('Dye density densitometer normalization coefficients:', norm_coeffs)
    dd[:,:3] = dd[:,:3] / norm_coeffs
    dc = dc * norm_coeffs
    
    profile.data.dye_density = dd
    profile.data.density_curves = dc
    return profile

def replace_fitted_density_curves(profile, control_plot=False):
    dc = profile.data.density_curves
    le = profile.data.log_exposure
    type = profile.info.type
    
    # fit density for smoother curves and complete toe and shoulder
    density_curves_fitting_parameters = fit_density_curves(le, dc, type=type)
    print('density_curves_fitting_parameters: ', density_curves_fitting_parameters)
    density_curves_prefit = np.copy(dc)
    dc = compute_density_curves(le, density_curves_fitting_parameters, type=type)
    profile.data.density_curves = dc
    profile.data.density_curves_layers = compute_density_curves_layers(le, density_curves_fitting_parameters, type=type)
    
    if control_plot:
        plt.figure()
        plt.plot(le, dc)
        plt.plot(le, density_curves_prefit, color='gray', linestyle='--')
        plt.legend(('r','g','b'))
        plt.xlabel('Log Exposure')
        plt.ylabel('Density (over B+F)')
    return profile

# def apply_gamma_shift_correction(profile):
#     p = copy.copy(profile)
#     dc = p.data.density_curves
#     le = p.data.log_exposure
#     gc = p.data.tune.gamma_correction
#     les = p.data.tune.log_exposure_correction
#     dc_out = np.zeros_like(dc)
#     for i in np.arange(3):
#         dc_out[:,i] = np.interp(le, le/gc[i] + les[i], dc[:,i])
#     p.data.density_curves = dc_out
#     return p


################################################################################
# Save and Load
################################################################################


def swap_channels(profile, new_cmy_order=(0,2,1)):
    profile.data.dye_density[:,:3] = profile.data.dye_density[:,new_cmy_order]
    return profile


################################################################################
# Processing and correction
################################################################################

def preprocess_profile(profile):
    profile = remove_density_min(profile)
    profile = adjust_log_exposure(profile)
    return profile

def process_negative_profile(raw_profile,
                    dye_density_reconstruct_model='dmid_dmin',
                    ):
    profile = copy.copy(raw_profile)
    profile = remove_density_min(profile)
    profile = adjust_log_exposure(profile)
    profile = reconstruct_dye_density(profile,
                                        control_plot=True,
                                        model=dye_density_reconstruct_model)
    profile = unmix_density(profile)
    profile = replace_fitted_density_curves(profile)
    profile = unmix_sensitivity(profile)
    profile = balance_sensitivity(profile)
    profile = replace_fitted_density_curves(profile)
    plot_profile(profile, unmixed=True, original=raw_profile)
    return profile

def process_paper_profile(raw_profile, align_midscale_exposures=False):
    profile = copy.copy(raw_profile)
    profile = remove_density_min(profile)
    profile = adjust_log_exposure(profile)
    profile = balance_metameric_neutral(profile)
    profile = unmix_density(profile)
    profile = replace_fitted_density_curves(profile)
    profile = unmix_sensitivity(profile)
    if align_midscale_exposures:
        profile = align_midscale_neutral_exposures(profile)
    profile = replace_fitted_density_curves(profile)
    plot_profile(profile, unmixed=True, original=raw_profile)
    return profile


################################################################################
# Save and Load
################################################################################

def plot_profile(profile, unmixed=False, original=None):
    wavelengths = profile.data.wavelengths
    log_exposure = profile.data.log_exposure
    density_curves = profile.data.density_curves
    log_sensitivity = profile.data.log_sensitivity
    dye_density = profile.data.dye_density
    
    # Plotting of data
    fig, axs = plt.subplots(1,3)
    fig.set_tight_layout(tight='rect')
    fig.set_figheight(4)
    fig.set_figwidth(12)
    axs[0].plot(wavelengths, log_sensitivity[:,0], color='tab:red')
    axs[0].plot(wavelengths, log_sensitivity[:,1], color='tab:green')
    axs[0].plot(wavelengths, log_sensitivity[:,2], color='tab:blue')
    axs[0].legend(('R','G','B'))
    axs[0].set_xlabel('Wavelength (nm)')
    if original is not None:
        axs[0].plot(wavelengths, original.data.log_sensitivity[:,0], alpha=0.5, color='tab:red', linestyle='--')
        axs[0].plot(wavelengths, original.data.log_sensitivity[:,1], alpha=0.5, color='tab:green', linestyle='--')
        axs[0].plot(wavelengths, original.data.log_sensitivity[:,2], alpha=0.5, color='tab:blue', linestyle='--')        
    axs[0].set_ylabel('Log sensitivity')
    axs[0].set_xlim((350, 750))
    
    D_lim = np.nanmax(density_curves)*1.05
    axs[1].plot(log_exposure, density_curves[:,0], color='tab:red', label='R')
    axs[1].plot(log_exposure, density_curves[:,1], color='tab:green', label='G')
    axs[1].plot(log_exposure, density_curves[:,2], color='tab:blue', label='B')
    axs[1].plot([0, 0], [0, D_lim], color='gray', linewidth=1, label='Ref')
    if profile.info.type == 'negative':
        le_3_stops = np.log10(2**3)
        axs[1].plot([-le_3_stops, -le_3_stops], [0, D_lim], 
                    color='lightgray', linestyle='dashed', linewidth=1, label='-3EV')
    if profile.info.type == 'paper':    axs[1].set_xlim((-1, 2))
    if profile.info.type == 'positive': axs[1].set_xlim((-2.5, 1.5))
    axs[1].legend()
    axs[1].set_xlabel('Log exposure')
    if unmixed: axs[1].set_ylabel('Layer density (over base+fog)')
    else:       axs[1].set_ylabel('Density (status '+profile.info.densitometer[-1]+', over base+fog)')
    
    axs[2].plot(wavelengths, dye_density[:,0], color='tab:cyan')
    axs[2].plot(wavelengths, dye_density[:,1], color='tab:pink')
    axs[2].plot(wavelengths, dye_density[:,2], color='gold')
    axs[2].plot(wavelengths, dye_density[:,3], color='gray', linewidth=1, linestyle='--')
    axs[2].plot(wavelengths, dye_density[:,4], color='gray', linewidth=1)
    axs[2].legend(('C','M','Y','Min','Mid'))
    if original is not None:
        axs[2].plot(wavelengths, original.data.dye_density[:,0], alpha=0.5, color='tab:cyan', linestyle='--')
        axs[2].plot(wavelengths, original.data.dye_density[:,1], alpha=0.5, color='tab:pink', linestyle='--')
        axs[2].plot(wavelengths, original.data.dye_density[:,2], alpha=0.5, color='gold', linestyle='--')
    axs[2].set_xlabel('Wavelength (nm)')
    axs[2].set_ylabel('Diffuse density')
    axs[2].set_xlim((350, 750))
    
    fig.suptitle(profile.info.name + ' - ' + profile.info.stock)

# TODO: add subfolters to the profile folder, this should also be added to save_profile and load_profile
# TODO: add masking couplers to the profiles as gamma matrix of masks, will require model changes

if __name__=='__main__':
    from agx_emulsion.profiles.io import load_profile
    # p = create_profile('kodak_portra_400')
    # p = create_profile('kodak_ultra_endura', type='paper')
    # save_profile(p, '_couplers_2')
    
    # p = create_profile('kodak_portra_endura', type='paper', densitometer='status_A')
    # plot_profile(p)
    # p = adjust_log_exposure_paper(p)
    # p = remove_density_min(p)
    # p = unmix_density(p)
    
    # plot_profile(p)
    # plt.show()
    
    # p = load_profile('kodak_portra_400_couplers_2')
    n_raw = load_profile('kodak_portra_400')
    n = load_profile('kodak_portra_400_auc')
    plot_profile(n_raw)
    plot_profile(n)
    
    p_raw = load_profile('kodak_portra_endura')
    p = load_profile('kodak_portra_endura_uc')
    plot_profile(p_raw)
    plot_profile(p)
    # print(p)
    # plt.show()
    plt.show()
