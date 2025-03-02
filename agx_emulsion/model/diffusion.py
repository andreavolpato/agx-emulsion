import numpy as np
import scipy.ndimage
# from agx_emulsion.utils.fast_gaussian_filter import fast_gaussian_filter
# from agx_emulsion.utils.fft_gaussian_filter import fft_gaussian_filter

def apply_unsharp_mask(image, sigma=0.0, amount=0.0):
    """
    Apply an unsharp mask to an image.
    
    Parameters:
    image (ndarray): The input image to be processed.
    sigma (float, optional): The standard deviation for the Gaussian sharp filter. Leave 0 if not wanted.
    amount (float, optional): The strength of the sharpening effect. Leave 0 if not wanted.
    
    Returns:
    ndarray: The processed image after applying the unsharp mask.
    """
    image_blur = scipy.ndimage.gaussian_filter(image, sigma=(sigma, sigma, 0))
    # image_blur = fast_gaussian_filter(image, sigma)
    image_sharp = image + amount * (image - image_blur)
    return image_sharp


def apply_halation_um(raw, halation, pixel_size_um):
    """
    Apply a halation effect to an image.

    Parameters:
    raw (numpy.ndarray): The input image array with shape (height, width, channels).
    halation_size (list or tuple): The size of the halation effect for each channel.
    halation_strength (list or tuple): The strength of the halation effect for each channel.
    scattering_size (list or tuple, optional): The size of the scattering effect for each channel. Default is [0, 0, 0].
    scattering_strength (list or tuple, optional): The strength of the scattering effect for each channel. Default is [0, 0, 0].

    Returns:
    numpy.ndarray: The image array with the halation effect applied.
    """
    
    halation_size_pixel = np.array(halation.size_um) / pixel_size_um
    halation_strength = np.array(halation.strength)
    scattering_size_pixel = np.array(halation.scattering_size_um) / pixel_size_um
    scattering_strength = np.array(halation.scattering_strength)
    
    if halation.active:
        for i in np.arange(3):
            if halation_strength[i]>0:
                raw[:,:,i] += halation_strength[i]*scipy.ndimage.gaussian_filter(raw[:,:,i], halation_size_pixel[i], truncate=7)
                raw[:,:,i] /= (1+halation_strength[i])
        # if np.any(halation_strength>0):
        #     raw += fast_gaussian_filter(raw, halation_size_pixel, truncate=7)*halation_strength
        #     raw /= (1+halation_strength)
                
        for i in np.arange(3):
            if scattering_strength[i]>0:
                raw[:,:,i] += scattering_strength[i]*scipy.ndimage.gaussian_filter(raw[:,:,i], scattering_size_pixel[i], truncate=7)
                raw[:,:,i] /= (1+scattering_strength[i])
        # if np.any(scattering_strength>0):
        #     raw += fast_gaussian_filter(raw, scattering_size_pixel)*scattering_strength
        #     raw /= (1+scattering_strength)
        
    return raw

def apply_gaussian_blur(data, sigma):
    if sigma > 0:
        return scipy.ndimage.gaussian_filter(data, (sigma, sigma, 0))
        data = np.double(data)
        data = np.ascontiguousarray(data)
        # return fast_gaussian_filter(data, sigma)
    else:
        return data
    
def apply_gaussian_blur_um(data, sigma_um, pixel_size_um):
    sigma = sigma_um / pixel_size_um
    if sigma > 0:
        # return scipy.ndimage.gaussian_filter(data, (sigma, sigma, 0))
        # data = np.double(data)
        # data = np.ascontiguousarray(data)
        return fast_gaussian_filter(data, sigma)
    else:
        return data