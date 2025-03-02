import numpy as np
from scipy.ndimage import gaussian_filter
# from agx_emulsion.utils.fast_gaussian_filter import fast_gaussian_filter
from opt_einsum import contract

def compute_density_curves_before_dir_couplers(density_curves, log_exposure, dir_couplers_matrix, high_exposure_couplers_shift=0.0):
    """
    DIR couplers affect the same layer by increasing contrast.
    I suppose that in the design of a film this is taken into account, and the final film has well behaved density curves.
    In order to get final curves for gray ramps equal to the input data, the density curves before the effect of the couplers are needed.

    Args:
        density_curves (numpy.array): Characteristic density curves of the film after the application of DIR couplers
        log_exposure (numpy.array): The image as log_exposure
        dir_couplers_matrix (_type_): DIR couplers matrix computed with compute_dir_couplers_matrix()
        high_exposure_couplers_shift (float, optional): Related to increased inhibition at high exposures, defaults to 0.0.

    Returns:
        _type_: _description_
    """
    d_max = np.nanmax(density_curves, axis=0)
    dc_norm = density_curves/d_max
    dc_norm_shift = dc_norm + high_exposure_couplers_shift*dc_norm**2
    couplers_amount_curves = contract('jk, km->jm', dc_norm_shift, dir_couplers_matrix)
    x0 = log_exposure[:,None] - couplers_amount_curves
    density_curves_corrected = np.zeros_like(density_curves)
    for i in np.arange(3):
        density_curves_corrected[:,i] = np.interp(log_exposure, x0[:,i], density_curves[:,i])
    return density_curves_corrected


def compute_dir_couplers_matrix(amount_rgb=[0.7,0.7,0.5], layer_diffusion=1):
    """
    Compute the inhibitors matrix using a simple diffusion model across layers.

    Parameters:
    amount_rgb (list of float): Amounts of dir couplers for RGB channels. Default is [0.7,0.7,0.5]. Typically 0-1 range.
    layer_diffusion (float): Sigma for gaussian diffusion distance of dir couplers. Default is 1.

    Returns:
    numpy.ndarray: The computed inhibitors matrix. Fisrt index is the input layer, second index is the output layer.
    """
    M = np.eye(3)
    M_diffused = gaussian_filter(M, layer_diffusion, mode='constant', cval=0, axes=1)
    M_diffused /= np.sum(M_diffused, axis=1)[:, None]
    M = M_diffused *np.array(amount_rgb)[:, None]
    return M

def compute_exposure_correction_dir_couplers(log_raw, density_cmy, density_max, dir_couplers_matrix, diffusion_size_pixel, high_exposure_couplers_shift=0.0):
    """
    Apply coupler inhibitors to the raw data based on density curves and inhibitor values.
    Coupler inhibitors are released when density is formed in the emulsion layers.
    If a layer is dense, the inhibitors are released to prevent further density formation in neighboring layers.
    Also self-inhibitors in the same layer, after spatial diffusion, can prevent further density formation
    in nearby areas, adding a local contrast effect.

    Parameters:
    raw (numpy.ndarray): The raw data to which inhibitors will be applied.
    density_cmy (numpy.ndarray): The density values for each layer.
    density_max (float): The maximum density value achievable for each layer, used for normalization.
    dir_couplers_matrix (numpy.ndarray): The inhibitors matrix. Fisrt index is the input layer, second index is the output layer.
    diffusion_size_pixel (int): The size of the gaussian filter for the diffusion of the inhibitors in xy.
    high_exposure_couplers_shift (float): if overexposure increases saturation, this will increase the inhibitors effect at higher density
    
    Returns:
    numpy.ndarray: The modified raw exposure data after applying the effect of inhibitors.
    """
    norm_density = density_cmy/density_max
    norm_density += high_exposure_couplers_shift*norm_density**2
    log_raw_correction = contract('ijk, km->ijm', norm_density, dir_couplers_matrix)
    if diffusion_size_pixel>0:
        log_raw_correction = gaussian_filter(log_raw_correction, (diffusion_size_pixel, diffusion_size_pixel, 0))
        # log_raw_correction = fast_gaussian_filter(log_raw_correction, diffusion_size_pixel)
    log_raw_corrected = log_raw - log_raw_correction
    return log_raw_corrected

# if __name__=='__main__':
    # # Test the raw correction coupler inhibitors
    # log_raw = np.ones((4,4,3))
    # density_cmy = np.ones((4,4,3))
    # density_max = 2.2
    # couplers_amount = [0.9,0.7,0.5]
    # diffusion_size_pixel = 2
    # log_raw = raw_correction_dir_couplers(log_raw, density_cmy, density_max, couplers_amount, diffusion_size_pixel)
    # print(log_raw)