import numpy as np
import scipy.ndimage

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
    image_sharp = image + amount * (image - image_blur)
    return image_sharp


def apply_halation(raw, halation_size_pixel, halation_strength, scattering_size_pixel=[0,0,0], scattering_strength=[0,0,0]):
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
    for i in np.arange(3):
        if halation_strength[i]>0:
            raw[:,:,i] += halation_strength[i]*scipy.ndimage.gaussian_filter(raw[:,:,i], halation_size_pixel[i], truncate=7)
            raw[:,:,i] /= (1+halation_strength[i])
            
    for i in np.arange(3):
        if scattering_strength[i]>0:
            raw[:,:,i] += scattering_strength[i]*scipy.ndimage.gaussian_filter(raw[:,:,i], scattering_size_pixel[i], truncate=7)
            raw[:,:,i] /= (1+scattering_strength[i])
    return raw