import numpy as np
import matplotlib.pyplot as plt
import scipy.interpolate
import scipy.special
import lmfit

from agx_emulsion.utils.io import load_densitometer_data
from agx_emulsion.utils.measure import measure_slopes_at_exposure

########################################################################################
# General functions

def low_pass_filter(wl, wl_max, width, amp=1.0):
    filt = 1 - amp*(scipy.special.erf((wl-wl_max)/width)+1)/2
    return filt
def high_pass_filter(wl, wl_min, width, amp=1.0):
    filt = 1 - amp + amp*(scipy.special.erf((wl-wl_min)/width)+1)/2
    return filt
def high_pass_gaussian(wl, wl_max, width, amount):
    gauss = amount * np.exp(-(wl-wl_max+width)**2/(2*width**2))
    return gauss
def low_pass_gaussian(wl, wl_max, width, amount):
    gauss = amount * np.exp(-(wl-wl_max-width)**2/(2*width**2))
    return gauss
def shift_stretch(wl, spectrum, amp=1.0, width=1.0, shift=0.0):
    center = wl[np.nanargmax(spectrum)]
    sel = ~np.isnan(spectrum)
    lam = 100
    sp = scipy.interpolate.make_smoothing_spline(wl[sel], spectrum[sel], lam=lam)
    spectrum_out = sp((wl-center)/width + center + shift)
    sp = scipy.interpolate.make_smoothing_spline(wl, spectrum_out, lam=lam)
    spectrum_out = sp(wl)
    spectrum_out[spectrum_out<0] = 0
    spectrum_out[~sel] = np.nan
    return amp*spectrum_out
def shift_stretch_cmy(wl, cmy, da0, dw0, ds0, # amplitude, stretch, shift
                               da1, dw1, ds1,
                               da2, dw2, ds2):
    c = shift_stretch(wl, cmy[:,0], da0, dw0, ds0)
    m = shift_stretch(wl, cmy[:,1], da1, dw1, ds1)
    y = shift_stretch(wl, cmy[:,2], da2, dw2, ds2)
    return np.vstack([c,m,y]).T
def gaussian_profiles(wl, p_couplers):
    density = np.zeros((np.size(wl), np.size(p_couplers, axis=0)))
    for i, ps in enumerate(p_couplers):
        density[:,i] += ps[0] * np.exp( -(wl-ps[2])**2/(2*ps[1]**2) )
    return density

########################################################################################
# models

def make_reconstruct_dye_density_params(model='model_a'):
    params = lmfit.Parameters()
    # dyes
    params.add('dye_amp0', value=1.0, min=0.5, max=1.5)
    params.add('dye_amp1', value=1.0, min=0.5, max=1.5)
    params.add('dye_amp2', value=1.0, min=0.5, max=1.5)
    params.add('dye_width0', value=1.0, min=0.9, max=1.1)
    params.add('dye_width1', value=1.0, min=0.9, max=1.1)
    params.add('dye_width2', value=1.0, min=0.9, max=1.1)
    params.add('dye_shift0', value=0.0, min=-30, max=30)
    params.add('dye_shift1', value=0.0, min=-30, max=30)
    params.add('dye_shift2', value=0.0, min=-30, max=30)
    
    if model[:6]=='filter':
        params.add('lp_c_width', value=20, min=12, max=30) # test
        params.add('hp_m_width', value=20, min=12, max=30)
        params.add('lp_y_width', value=20, min=12, max=30)
        params.add('lp_m_width', value=20, min=12, max=30)
        params.add('hp_c_width', value=20, min=12, max=30)
        params.add('lp_c_wl', value=420, min=400, max=440) # test
        params.add('hp_m_wl', value=500, min=460, max=500)
        params.add('lp_y_wl', value=500, min=490, max=530)
        params.add('lp_m_wl', value=600, min=590, max=650)
        params.add('hp_c_wl', value=600, min=570, max=600)
    
    if model=='filters_neg':
        # negative components to make density zero on densitometer
        params.add('high_y',  value=-0.02, min=-0.1, max=0.0)
        params.add('low_m',   value=-0.02, min=-0.1, max=0.0)
        params.add('high_m',  value=-0.02, min=-0.1, max=0.0)
        params.add('low_c',   value=-0.02, min=-0.1, max=0.0)
        params.add('low_c_y', value=-0.02, min=-0.1, max=0.0) # test
    
    if model[:10]=='filteramps':
        params.add('lp_c_amp', value=0.8, min=0.0, max=1.0)
        params.add('hp_m_amp', value=0.8, min=0.0, max=1.0)
        params.add('lp_y_amp', value=0.8, min=0.0, max=1.0)
        params.add('lp_m_amp', value=0.8, min=0.0, max=1.0)
        params.add('hp_c_amp', value=0.8, min=0.0, max=1.0)

    if model=='dmid_dmin':
        # couplers
        params.add('cpl_amp0', value=0.1, min=0.05, max=0.5)
        params.add('cpl_amp1', value=0.1, min=0.05, max=0.5)
        params.add('cpl_amp2', value=0.1, min=0.05, max=0.5)
        params.add('cpl_amp3', value=0.03, min=0.0, max=0.5)
        params.add('cpl_amp4', value=0.1, min=0.05, max=0.5)
        params.add('cpl_width0', value=20, min=10, max=40)
        params.add('cpl_width1', value=20, min=10, max=40)
        params.add('cpl_width2', value=20, min=10, max=40)
        params.add('cpl_width3', value=40, min=10, max=50)
        params.add('cpl_width4', value=20, min=10, max=40)
        params.add('cpl_max0', value=435, min=420, max=450)
        params.add('cpl_max1', value=560, min=540, max=600)
        params.add('cpl_max2', value=475, min=455, max=490)
        params.add('cpl_max3', value=700, min=650, max=720)
        params.add('cpl_max4', value=510, min=495, max=535)
        # others
        params.add('dmax1', value=2.3, min=2.0, max=5)
        params.add('dmax0', value=2.3, min=2.0, max=5)
        params.add('dmax2', value=2.3, min=2.0, max=5)
        # params.add('dmax3', value=2.3, min=0.5, max=5)
        # params.add('dmax4', value=2.3, min=0.5, max=5)
        params.add('fog0', value=0.07, min=0.05, max=0.10, vary=True)
        params.add('fog1', value=0.07, min=0.05, max=0.10, vary=True)
        params.add('fog2', value=0.07, min=0.05, max=0.10, vary=True)
        params.add('scat400', value=0.65, min=0.62, max=1.0)
        params.add('base', value=0.05, min=0, max=0.15)
    return params

def density_mid_min_model(params, wl, cmy_model, model):
    dmin = np.zeros_like(wl)
    dye = shift_stretch_cmy(wl, cmy_model, params['dye_amp0'], params['dye_width0'], params['dye_shift0'],
                                        params['dye_amp1'], params['dye_width1'], params['dye_shift1'],
                                        params['dye_amp2'], params['dye_width2'], params['dye_shift2'],)
    if model[:7]=='filters':
        hp_m = high_pass_filter(wl, params['hp_m_wl'], params['hp_m_width'])
        lp_y = low_pass_filter( wl, params['lp_y_wl'], params['lp_y_width'])
        lp_m = low_pass_filter( wl, params['lp_m_wl'], params['lp_m_width'])
        hp_c = high_pass_filter(wl, params['hp_c_wl'], params['hp_c_width'])
        lp_c = low_pass_filter( wl, params['lp_c_wl'], params['lp_c_width'])
        filters = np.stack((1-(1-hp_c)*(1-lp_c),
                            hp_m*lp_m,
                            lp_y), axis=1)
    if model=='filters':
        cmy = dye*filters
    if model=='filters_neg':
        cmy = dye*filters
        cmy[:,2] += ((1-lp_y)*(1-hp_c))*6*params['high_y']
        cmy[:,1] += (1-lp_m)*params['low_m']
        cmy[:,1] += (1-hp_m)*params['high_m']
        cmy[:,0] += ((1-lp_y)*(1-hp_c))**6*params['low_c']
        cmy[:,0] += ((1-hp_m)*(1-lp_c))**6*params['low_c_y'] # test
    
    ########## filters with amplitudes ##########
    
    if model[:10]=='filteramps':
        hp_m = high_pass_filter(wl, params['hp_m_wl'], params['hp_m_width'], params['hp_m_amp'])
        lp_y = low_pass_filter(wl, params['lp_y_wl'], params['lp_y_width'], params['lp_y_amp'])
        lp_m = low_pass_filter(wl, params['lp_m_wl'], params['lp_m_width'], params['lp_m_amp'])
        hp_c = high_pass_filter(wl, params['hp_c_wl'], params['hp_c_width'], params['hp_c_amp'])
        lp_c = low_pass_filter(wl, params['lp_c_wl'], params['lp_c_width'], params['lp_c_amp']) # test
        filters = np.stack((1-(1-hp_c)*(1-lp_c),
                            hp_m*lp_m,
                            lp_y), axis=1)
    if model=='filteramps':
        cmy = dye*filters
    if model=='filteramps_gauss':
        hp_c_gauss = high_pass_gaussian(wl, params['hp_c_wl'], params['hp_c_width'], params['hp_c_amp'])
        lp_c_gauss = low_pass_gaussian(wl, params['lp_c_wl'], params['lp_c_width'], params['lp_c_amp'])
        hp_m_gauss = high_pass_gaussian(wl, params['hp_m_wl'], params['hp_m_width'], params['hp_m_amp'])
        lp_m_gauss = low_pass_gaussian(wl, params['lp_m_wl'], params['lp_m_width'], params['lp_m_amp'])
        lp_y_gauss = low_pass_gaussian(wl, params['lp_y_wl'], params['lp_y_width'], params['lp_y_amp'])
        filters = np.stack((1-(1-hp_c)*(1-lp_c),
                            hp_m*lp_m,
                            lp_y), axis=1)
        gauss = np.stack((hp_c_gauss+lp_c_gauss,
                        hp_m_gauss+lp_m_gauss,
                        lp_y_gauss), axis=1)
        # filters[:,0] += lp_c # test
        cmy = dye*filters - gauss
        
    ########## dmid dmin ##########
    
    if model=='dmid_dmin':
        channels_couplers_gaussians = [0,0,1,1,2]
        p_couplers = [[params['cpl_amp0'], params['cpl_width0'], params['cpl_max0']],
                    [params['cpl_amp1'], params['cpl_width1'], params['cpl_max1']],
                    [params['cpl_amp2'], params['cpl_width2'], params['cpl_max2']],
                    [params['cpl_amp3'], params['cpl_width3'], params['cpl_max3']],
                    [params['cpl_amp4'], params['cpl_width4'], params['cpl_max4']]]
        cpl = gaussian_profiles(wl, p_couplers)
        cpl_cmy = np.zeros((np.size(wl), 3))
        for i in range(5):
            cpl_cmy[:,channels_couplers_gaussians[i]] += cpl[:,i]
        cmy = dye-cpl_cmy
        dmin, _, _, _, _, _ = density_min_model(params, wl, cmy, cpl, channels_couplers_gaussians)
        filters = cpl
    
    return cmy, dye, filters, dmin

def density_min_model(params, wl, cmy, cpl, channels_couplers_gaussians):
    dcmy = [params['dye_amp0'], params['dye_amp1'], params['dye_amp2']]
    dmax = np.array([params['dmax0'], 
                    params['dmax1'], 
                    params['dmax2'],
                    # params['dmax3'],
                    # params['dmax4']
                    ])
    fog = np.array([params['fog0'],
                    params['fog1'],
                    params['fog2'],])
    base = np.ones_like(wl)*params['base']
    scattering = -np.log10(1-params['scat400']*400**4/wl**4)
    cpl_cmy = np.zeros_like(cmy)
    for i in range(5):
        # cpl_cmy[:,channels_couplers_gaussians[i]] += cpl[:,i]/dcmy[channels_couplers_gaussians[i]]*dmax[i]
        cpl_cmy[:,channels_couplers_gaussians[i]] += cpl[:,i]/dcmy[channels_couplers_gaussians[i]]*dmax[channels_couplers_gaussians[i]]
    dmin = np.sum(cpl_cmy + fog*cmy, axis=1) + scattering + base
    return dmin, cpl_cmy, scattering, fog, base, dmax

########################################################################################

def slopes_of_concentrations(log_exposure, density_curves, dstm_cm):
    c = np.zeros_like(density_curves)
    for i in range(3):
        for j in range(3):
            c[:,i] += np.linalg.inv(dstm_cm)[i,j] * density_curves[:,j] # TODO fix order of indexes of crosstalk matrix according to formalism
    gammas = measure_slopes_at_exposure(log_exposure, c)
    return gammas

def residual_simple(params, wl, cmy_model, data, dstm, paper_sens, log_exposure, density_curves, model='model_a', biases=(1,2,2)):
    cmy, _, _, min_sim = density_mid_min_model(params, wl, cmy_model, model)
        
    # bias for out of diagonal crosstalk
    paper_cm = compute_densitometer_crosstalk_matrix(paper_sens, cmy)
    out_of_diagonal_crosstalk = paper_cm.flatten()[[1,2,3,5,6,7]]
    # bias for parallel gammas
    dstm_cm = compute_densitometer_crosstalk_matrix(dstm, cmy)
    gammas = slopes_of_concentrations(log_exposure, density_curves, dstm_cm)
    diff_gammas= gammas - np.mean(gammas)
    
    mid_minus_min_sim = np.sum(cmy, axis=1)
    sim = np.concatenate((mid_minus_min_sim, biases[0]*min_sim))
    res = data - sim
    res = np.concatenate((res, biases[1]*out_of_diagonal_crosstalk, biases[2]*diff_gammas)) # add crosstalk matrix to the loss function
    # 20 is an empirical bias to balance the weight of the crosstalk matrix in the loss function
    return res

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

########################################################################################
# Main function

from agx_emulsion.model.illuminants import standard_illuminant
from agx_emulsion.model.color_filters import dichroic_filters

def reconstruct_dye_density(profile, params=None, control_plot=False, print_params=False,
                            target_print_paper=None, ymc_filter_values=[0.8,0.6,0.2],
                            max_nfev=500, tol=5e-5, model='dmid_dmin', biases=(1,2,0)
                            ):
    cmy_model = profile.data.dye_density[:,:3]
    wl = profile.data.wavelengths
    le = profile.data.log_exposure
    dc = profile.data.density_curves
    dmid = profile.data.dye_density[:,4]
    dmin = profile.data.dye_density[:,3]
    dmid_minus_min = dmid-dmin
    exp = np.concatenate((dmid_minus_min, dmin))
    
    dstm = load_densitometer_data(profile.info.densitometer)
    if target_print_paper is not None:
        paper_sens = 10**target_print_paper.data.log_sensitivity
        illuminant = standard_illuminant('BB3200')
        filtered_illuminat = dichroic_filters.apply(illuminant, values=ymc_filter_values)
        paper_sens = paper_sens * filtered_illuminat[:, None]
        # paper_sens[:,1] = dstm[:,1]
        # paper_sens[:,2] = dstm[:,2]
        
        plt.figure()
        plt.plot(wl, paper_sens)
    else:
        paper_sens = dstm

    if params is None:
        params = make_reconstruct_dye_density_params(model)
        
    out = lmfit.minimize(residual_simple, params,
                         args=(wl, cmy_model, exp, dstm, paper_sens, le, dc, model, biases),
                         nan_policy='omit', method='least_squares',
        **{
        'ftol': tol,
        'xtol': tol,
        'gtol': tol,
        'max_nfev': max_nfev
        })
    
    cmy, cmy_nofilt, filters, dmin_sim = density_mid_min_model(out.params, wl, cmy_model, model)

    dstm_cm = compute_densitometer_crosstalk_matrix(dstm, cmy)
    g = slopes_of_concentrations(le, dc, dstm_cm)
    
    if print_params:
        print('----------------------------------------')
        print('Reconstructed Dye Density Parameters')
        out.params.pretty_print()
        print('Slopes of conc. at le=0:', g)
        print('Crosstalk matrix:')
        print(dstm_cm)
    
    if control_plot:
        
        color = ['tab:cyan', 'tab:pink', 'gold']
        
        fig, axs = plt.subplots(1,3)
        fig.set_tight_layout(tight='rect')
        fig.set_figheight(4)
        fig.set_figwidth(12)
        fig.suptitle(profile.info.name)
    
        for i in range(3):
            axs[0].plot(wl, cmy[:,i], color=color[i], label='CMY'[i])
        axs[0].plot(wl, np.sum(cmy, axis=1), 'k--', label='Sim', alpha=0.5)
        axs[0].plot(wl, dmid_minus_min, 'k', label='Exp')
        axs[0].legend()
        axs[0].set_xlabel('Wavelength (nm)')
        axs[0].set_ylabel('Diffuse Density')
        axs[0].set_title('Midscale neutral minus minimum')

        for i in range(3):
            axs[1].plot(wl, cmy_nofilt[:,i], '--', color=color[i], label='_nolegend_')
            # axs[1].plot(wl, -cpl[:,i], color='tab:purple', label='_nolegend_')
            axs[1].plot(wl, cmy[:,i], color=color[i], alpha=1.0, label='CMY'[i])
        axs[1].text(
                0.5,            # x-position (in axes fraction)
                0.02,           # y-position (in axes fraction) 
                'Dashed lines are without masking couplers.', 
                transform=axs[1].transAxes, 
                ha='center',    # horizontal alignment
                va='bottom',    # vertical alignment
                fontsize=9, 
                color='k'
            )
        axs[1].set_xlabel('Wavelength (nm)')
        axs[1].set_ylabel('Diffuse Density')
        axs[1].set_title('CMY and masking couplers')
        axs[1].legend()
        
        if model=='dmid_dmin':
            dmin_sim, cpl, scat, fog, base, dmax = density_min_model(out.params, wl, cmy, filters, [0,0,1,1,2])
            axs[2].plot(wl, np.ones_like(wl)*base, 'tab:green', label='Base')
            axs[2].plot(wl, base+scat, 'tab:blue', label='Scattering')
            axs[2].plot(wl, base+scat+np.sum(fog*cmy, axis=1) + cpl[:,0], color='tab:cyan', label='Mask C')
            axs[2].plot(wl, base+scat+np.sum(fog*cmy, axis=1) + cpl[:,1], color='tab:pink', label='Mask M')
            axs[2].plot(wl, base+scat+np.sum(fog*cmy, axis=1) + cpl[:,2], color='gold', label='Mask Y')
            axs[2].plot(wl, base+scat+np.sum(fog*cmy, axis=1), color='tab:orange', label='Fog')
            axs[2].plot(wl, dmin_sim, 'k--', label='Sim', alpha=0.5)
        else:
            for i in range(3):
                axs[2].plot(wl, filters[:,i], color=color[i], label='CMY'[i])
        axs[2].plot(wl, dmin, 'k', label='Exp')
        axs[2].set_xlabel('Wavelength (nm)')
        axs[2].set_ylabel('Diffuse Density')
        axs[2].set_title('Minimum density')
        axs[2].set_ylim([0, np.nanmax(dmin)*1.05])
        axs[2].legend()
            
            

    profile.info.density_midscale_neutral = np.nanmax(cmy, axis=0).tolist()
    profile.data.dye_density[:,:3] = cmy/np.nanmax(cmy, axis=0)
    # profile.info.density_midscale_neutral = np.nanmax(cmy[:,1])
    # profile.data.dye_density[:,:3] = cmy/np.nanmax(cmy[:,1])
    return profile


if __name__ == '__main__':
    from agx_emulsion.profiles.io import load_profile
    
    # params = make_reconstruct_dye_density_params()
    # profile = load_profile('kodak_portra_400_v2')
    # profile = load_profile('fuji_pro_400h_v2')
    # profile = load_profile('kodak_vision3_50D')
    # paper = load_profile('kodak_ektacolor_edge')
    # paper = load_profile('kodak_portra_endura')
    # paper = load_profile('fuji_crystal_archive_typeii_unmix_corrected')
    negatives = [
                 'kodak_portra_400',
                 'fujifilm_pro_400h',
                 'kodak_vision3_50d'
                 ]
    for neg in negatives:
        profile = load_profile(neg)
        profile = reconstruct_dye_density(profile,
                                          control_plot=True,
                                          print_params=True)

    # profile = process_profile(profile)
    # plot_profile(profile)
    plt.show()