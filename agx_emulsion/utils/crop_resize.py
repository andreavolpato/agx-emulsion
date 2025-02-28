import numpy as np
import skimage.transform

def crop_image(image, center=(0.5,0.5), size=(0.1, 0.1)):
    """
    Crop an image based on a specified fraction and center.

    Parameters:
    image (numpy.ndarray): The input image to be cropped.
    center (tuple of float, optional): The center of the cropping area as a tuple of two floats (x, y). 
                                      Each value should be between 0 and 1. Default is (0.5, 0.5).
    size (tuple of float, optional): The normalize size of the cropped area as fraction of the long side, (x,y). Default is (0.1, 0.1).

    Returns:
    numpy.ndarray: The cropped image.
    """
    center = np.flip(center)
    shape = image.shape[0:2]
    cn = np.round(shape*np.array(center))
    sz = np.round(np.double(np.max(shape))*np.flip(np.array(size)))
    x0 = np.round(cn - sz/2)
    sz = np.int64(sz)
    x0 = np.int64(x0)
    x0[x0<0] = 0
    if x0[0]+sz[0]>shape[0]: x0[0] = shape[0]-sz[0]
    if x0[1]+sz[1]>shape[1]: x0[1] = shape[1]-sz[1]
    image_crop = image[x0[0]:x0[0]+sz[0], x0[1]:x0[1]+sz[1],:]
    return image_crop

# def resize_image(image, resize_factor=1.0): #TBD
#     """
#     Resize the given image by a specified factor.
#     Parameters:
#     image (numpy.ndarray): The image to be resized.
#     resize_factor (float, optional): The factor by which to resize the image. 
#                                      Default is 1.0 (no resizing).
#     Returns:
#     numpy.ndarray: The resized image.
#     """
#     # zoom(image, zoom=(resize_factor, resize_factor, 1.0))
#     return skimage.transform.rescale(image, resize_factor, channel_axis=2)