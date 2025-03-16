import numpy as np
import scipy
import matplotlib.pyplot as plt
import scipy.special
import scipy.stats
from agx_emulsion.utils.fast_interp import fast_interp

################################################################################
# Density curve models
################################################################################
def density_curve_model_norm_cdfs(loge,
                        x=[
                              0, 1, 2, # centers
                              0.5, 0.5, 0.5, # amplitudes
                              0.3, 0.5, 0.7, # sigmas
                             ],
                        type='negative',
                        number_of_layers = 3,
                        ):
    centers    = x[0:3]
    amplitudes = x[3:6]
    sigmas     = x[6:9]
    
    dloge_curve = np.zeros(loge.shape)
    for i, (center, amplitude, sigma) in enumerate(zip(centers,amplitudes,sigmas)):
        if i <= number_of_layers-1:
            if type=='positive':
                dloge_curve += scipy.stats.norm.cdf( -(loge-center)/sigma )*amplitude
            else:
                dloge_curve += scipy.stats.norm.cdf(  (loge-center)/sigma )*amplitude
    return dloge_curve

def distribution_model_norm_cdfs(loge, x, number_of_layers = 3,):
    centers    = x[0:3]
    amplitudes = x[3:6]
    sigmas     = x[6:9]
    
    distribution = np.zeros((loge.shape[0], 3))
    for i, (center, amplitude, sigma) in enumerate(zip(centers,amplitudes,sigmas)):
        if i <= number_of_layers-1:
            distribution[:,i] += scipy.stats.norm.pdf(  (loge-center)/sigma )*amplitude
    return distribution

def density_curve_layers(loge,
                         x,
                         type='negative',
                         number_of_layers=3):  
    N = number_of_layers
    centers    = x[0  : N  ]
    amplitudes = x[N  : 2*N]
    sigmas     = x[2*N: 3*N]
    
    dloge_curve = np.zeros((loge.shape[0], 3))
    for i, (center, amplitude, sigma) in enumerate(zip(centers,amplitudes,sigmas)):
        if i <= number_of_layers-1:
            if type=='positive':
                dloge_curve[:,i] += scipy.stats.norm.cdf( -(loge-center)/sigma )*amplitude
            else:
                dloge_curve[:,i] += scipy.stats.norm.cdf(  (loge-center)/sigma )*amplitude
    return dloge_curve

def guess_start_and_bounds_norm_cdfs(loge, data, type):
    range = np.max(data) - np.min(data)
    if np.logical_or(type=='positive', type=='paper'):
        x0 = [
            np.mean(loge)-0.25, np.mean(loge), np.mean(loge)+0.25, # centers
            0.5, 1, 0.5, # amplitudes
            0.2, 0.3, 0.5, # sigmas
            ]
        x_lb = [
            np.min(loge), np.min(loge), np.min(loge),
            0.25, 0.25, 0.25,
            0.05, 0.05, 0.05,
            ]
        x_ub = [
            np.max(data), np.max(data), np.max(data),
            5.0, 5.0, 5.0,
            1, 1, 1,
            ]
    elif type=='negative':
        density_max_layer = 1.35
        x0 = [
            np.mean(loge)-0.5, np.mean(loge), np.mean(loge)+0.5, # centers
            0.5, 0.5, 0.5, # amplitudes
            0.3, 0.6, 0.9, # sigmas
            ]
        x_lb = [
                np.min(loge), np.min(loge), np.min(loge),
                0.2, 0.2, 0.2, # 0.35 in order to have a larger sensitive layer
                0.05, 0.05, 0.05,
                ]
        x_ub = [
                np.max(data), np.max(data), np.max(data),
                density_max_layer, density_max_layer, density_max_layer,
                2, 2, 2,
                ]
    return x0, (x_lb, x_ub)

# Effective model
def density_curve_model_log_line(logE,
                               x_in=[0.1, 1.5, -2.5,  2,
                                    2,   2,
                                   .2,   0, .2, 0,
                                 ],
                               type='negative',
                               ):
    x = np.zeros(10)
    x[0:10] = x_in[0:10]
    D_min = x[0] # minimum density
    gamma = x[1] # slope of the linear part D-logE
    H_reference = x[2] # logE value of the intersection Dmin baseline and linear part
    D_range = x[3] # maximum density (reached by the linear part)
    curvature_toe = x[4] # curvature of the toe region, the highest the sharpest
    curvature_shoulder = x[5] # curvature of the shoulder region, the highest the sharpest
    curvature_toe_slope = x[6]
    curvature_toe_max = x[7]
    curvature_shoulder_slope = x[8]
    curvature_shoulder_max = x[9]
    
    if type=='negative':
        H0 = H_reference - 1.0/gamma # 1.671 = log10((1/255)/0.184) minimum sRGB value over black
    else:
        H0 = H_reference - 0.735/gamma # 0.735 is log10(1/0.184) density for 0.184 transmittance
    
    if type=='positive':
        gamma = - gamma
        curvature_toe_slope = -curvature_toe_slope
        curvature_shoulder_slope = -curvature_shoulder_slope

    def sigmoid(x):
        return 1/(1+np.exp(-4*gamma*x))
    morph_shoulder = gamma*(curvature_shoulder)*(
        1 + curvature_shoulder_max*sigmoid(-curvature_shoulder_slope * (logE - H0 - D_range/gamma) ))
    morph_toe = gamma*(curvature_toe)*(
        1 + curvature_toe_max*sigmoid(curvature_toe_slope * (logE - H0 ) ))
    
      
    rise = gamma/morph_toe * np.log10(1 + 
              10**( morph_toe * (logE - H0) ) )
    stop = (gamma)/morph_shoulder * np.log10(1 +
              10**(morph_shoulder * (logE - D_range/np.abs(gamma) - H0)) )
    if type=='positive':
        D = D_min - rise + stop
    else:
        D = D_min + rise - stop
    return D

def guess_start_and_bounds_log_line(loge, data, type):
        if np.logical_or(type=='positive', type=='paper'):
                s = 2
        else:
                s = 1
        x0 = [
        np.min(data), # D_min
        (np.max(data)-np.min(data))/(np.max(loge)-np.min(loge))*2, # gamma
        np.mean(loge), # H_ref
        2.2, # D_range
        3, # curvature_toe
        2, # curvature_shoulder
        0, 0,
        0, 0,
        ]
        x_lb = [0, # D_min
                0, # gamma  
                np.min(loge), # H_ref
                0, # D_range
                0.5, # curvature_toe
                0.5, # curvature_shoulder
                -4, 0,   # toe shape
                -4, 0, # shoulder shape
                ]
        x_ub = [np.min(data)+1, # D_min
                5, # gamma
                np.max(loge), # H_ref
                3.5, # D_range
                16, # curvature_toe
                4, # curvature_shoulder
                8, 4*s, # toe shape, slope-max
                8, 4*s, # shoulder shape, slope-max
                ]
        return x0, (x_lb, x_ub)

def compute_density_curves(log_exposure, parameters, type, model='norm_cdfs'):
    density_out = np.zeros((np.size(log_exposure), 3))
    if model=='norm_cdfs':
        model_function = density_curve_model_norm_cdfs
    if model=='log_line':
        model_function = density_curve_model_log_line
    for i in np.arange(3):
        density_out[:,i] = model_function(log_exposure, parameters[i], type)
    return density_out

def compute_density_curves_layers(log_exposure, parameters, type):
    density_out = np.zeros((np.size(log_exposure), 3, 3))
    for i in np.arange(3):
        density_out[:,:,i] = density_curve_layers(log_exposure, parameters[i], type)
    return density_out

################################################################################
# Fitting
################################################################################

def fit_density_curve(loge, data,
                      type='negative',
                      model='norm_cdfs'):
    if model=='norm_cdfs':
        model_function = density_curve_model_norm_cdfs
        guesses = guess_start_and_bounds_norm_cdfs
    if model=='log_line':
        model_function = density_curve_model_log_line
        guesses = guess_start_and_bounds_log_line
    nan_sel = np.isnan(data)
    loge = loge[~nan_sel]
    data = data[~nan_sel]
    x0, bounds = guesses(loge, data, type)
    residues = lambda x: data - model_function(loge, x, type)
    fit = scipy.optimize.least_squares(residues,x0,bounds=bounds)
    return fit.x

def fit_density_curves(density,
                       model='norm_cdfs',
                       type='negative', stock='film_stock', plotting=False):
    fitted_parameters = np.zeros((3,9))
    log_exposure = density.log_exposure
    if model=='norm_cdfs':
        model_function = density_curve_model_norm_cdfs
    if model=='log_line':
        model_function = density_curve_model_log_line

    for i in np.arange(3):
        fitted_parameters[i] = fit_density_curve(log_exposure, density.raw_data[:,i],
                                                 type, model=model)

    if plotting:
        print(fitted_parameters)
        _, ax = plt.subplots()
        colors = ['tab:red','tab:green','tab:blue']        
        for i in np.arange(3):
            ax.plot(log_exposure, density.raw_data[:,i], '.', color='k', label='_nolegend_')
            ax.plot(log_exposure, model_function(log_exposure, fitted_parameters[i], type), color=colors[i])
            if model=='norm_cdfs':
                ax.plot(log_exposure, distribution_model_norm_cdfs(log_exposure, fitted_parameters[i]),
                        label='_nolegend_', color=colors[i], linewidth=1, linestyle='dashed')
            ax.set_xlabel('Log Exposure')
            ax.set_ylabel('Density')
            ax.set_title(stock+' - '+type)
            ax.legend(('r','g','b'))
    return fitted_parameters

################################################################################
# Denstity curves
################################################################################

def interpolate_exposure_to_density(log_exposure_rgb, density_curves, log_exposure, gamma_factor):
    """
    Interpolates the exposure values to density values using the provided density curves.
    Parameters:
    log_exposure_rgb (numpy.ndarray): A 3D array of shape (height, width, 3) representing the log10 RGB exposure values.
    density_curves (numpy.ndarray): A 2D array of shape (num_points, 3) representing the density curves for each channel.
    log_exposure (numpy.ndarray): A 1D array of logarithmic exposure values.
    gamma_factor (float): The gamma correction factor to be applied to the density characteristic curves.
    Returns:
    numpy.ndarray: A 3D array of shape (height, width, 3) representing the interpolated density values in CMY channels.
    """
    if np.size(gamma_factor)==1:
        gamma_factor = [gamma_factor, gamma_factor, gamma_factor]
    gamma_factor = np.array(gamma_factor)
    density_cmy = np.zeros((log_exposure_rgb.shape[0], log_exposure_rgb.shape[1], 3))
    # for channel in np.arange(3):
    #     sel = ~np.isnan(density_curves[:,channel])
    #     density_cmy[:,:,channel] = np.interp(log_exposure_rgb[:,:,channel],
    #                                          log_exposure[sel]/gamma_factor[channel],
    #                                          density_curves[sel,channel])
    density_cmy = fast_interp(np.ascontiguousarray(log_exposure_rgb),
                              log_exposure[:,None]/gamma_factor[None,:],
                              density_curves)
    return density_cmy
    
# This method was used for multilayer grain, but it is not used anymore
# def interpolate_layers(self, exposure_rgb):
#     density_curves_layers = density_curves_layers_model(self.log_exposure, self.parameters, self.type)
#     density_cmy_layers = np.zeros((exposure_rgb.shape[0], exposure_rgb.shape[1], 3, 3))
#     exposure = 10**(self.log_exposure)
#     for channel in np.arange(3):
#         for layer in np.arange(3):
#             density_cmy_layers[:,:,channel,layer] = np.interp(exposure_rgb[:,:,channel],
#                                                               exposure,
#                                                               density_curves_layers[:,channel,layer])
#     return density_cmy_layers

################################################################################
# tuning of curves
################################################################################

def apply_gamma_shift_correction(log_exposure, density_curves, gamma_correction, log_exposure_correction):
    dc = density_curves
    le = log_exposure
    gc = gamma_correction
    les = log_exposure_correction
    dc_out = np.zeros_like(dc)
    for i in np.arange(3):
        dc_out[:,i] = np.interp(le, le/gc[i] + les[i], dc[:,i])
    return dc_out


################################################################################
# Fit stocks and evaluate results
################################################################################
# if __name__=='__main__':
    # # TODO: fix the multilayer situation. Now the fitting is performed in unmix_profile() inside profiles.py
    # from agx_emulsion.profiles.factory import load_agx_emulsion_data
    # np.set_printoptions(precision=2, suppress='True')
    # save_flag = False
    # types =  ['negative',          'negative',         'paper',                'paper',               'positive']
    # stocks = ['kodak_vision3_50d', 'kodak_portra_400', 'kodak_ektacolor_edge', 'kodak_portra_endura', 'fujifilm_provia_100f']
    # models = ['norm_cdfs',         'norm_cdfs',        'norm_cdfs',            'norm_cdfs',           'norm_cdfs']
    # for type, stock, model in zip(types,stocks,models):
    #     print(stock+' - '+type)
    #     _, _, _, c, _ = load_agx_emulsion_data(data_folder='agx_emulsion/data/', stock=stock, type=type)
    #     fitted_parameters = fit_density_curves(c, plotting=True, type=type, stock=stock, model=model)
    #     if save_flag:
    #         np.savetxt('agx_emulsion/data/color/'+type+'/'+stock+'/density_curves_fitted_parameters.csv', fitted_parameters)
    #         plt.savefig('agx_emulsion/data/color/'+type+'/'+stock+'/density_curves_fitted_model.png')
    # plt.show()