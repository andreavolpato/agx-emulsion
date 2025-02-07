import png
import imageio.v3
import numpy as np
import scipy.interpolate
import json
import importlib.resources as pkg_resources
from dotmap import DotMap
import copy
import os

from agx_emulsion.config import LOG_EXPOSURE, SPECTRAL_SHAPE

################################################################################
# 16-bit PNG I/O
################################################################################

def read_png_16bit(filename, return_double=True):
    img_array = imageio.v3.imread(filename, plugin='PNG-FI')  # 16-bit
    bitdepth = 16
    # reader = png.Reader(filename)
    # width, height, rows, info = reader.read_flat()  # returns a generator
    # bitdepth = info["bitdepth"]   # should be 16 for 16-bit
    # planes   = info["planes"]     # e.g. 1=grayscale, 3=RGB, 4=RGBA
    # # rows is a 1D array-like of all pixel data
    # assert bitdepth in [8, 16], "Only 8-bit and 16-bit PNGs are supported"
    # if bitdepth == 16:
    #     img_array = np.array(rows, dtype=np.uint16)  # We expect 16-bit data
    # if bitdepth == 8:
    #     img_array = np.array(rows, dtype=np.uint8)
    # # Reshape to (height, width, channels)
    # img_array = img_array.reshape((height, width, planes))
    img_array = img_array[:,:,0:3] # remove alpha if present
    if return_double:
        img_array = np.double(img_array)
        img_array /= 2**bitdepth-1
    return img_array

def read_png(filename, return_double=True):
    img_array = imageio.v3.imread(filename)
    bitdepth = 8
    img_array = img_array[:,:,0:3] # remove alpha if present
    if return_double:
        img_array = np.double(img_array)
        img_array /= 2**bitdepth-1
    return img_array

def save_png_16bit(float_array, filename='image_16bit.png'):
    scaled = float_array / np.max(float_array)
    scaled = (float_array * 65535).astype(np.uint16)
    height, width, channels = scaled.shape
    # pypng wants a 2D list of rows
    reshaped = scaled.reshape(height, width * channels)
    with open(filename, 'wb') as f:
        writer = png.Writer(width, height, bitdepth=16, greyscale=False)
        writer.write(f, reshaped)


################################################################################
# Interpolation
################################################################################

def interpolate_to_common_axis(data, new_x,
                               extrapolate=False, method='cubic'):
    x = data[0]
    y = data[1]
    sorted_indexes = np.argsort(x)
    x = x[sorted_indexes]
    y = y[sorted_indexes]
    if method=='cubic':
        interpolator = scipy.interpolate.CubicSpline(x, y, extrapolate=extrapolate)
    elif method=='linear':
        def interpolator(x_new):
            return np.interp(x_new, x, y) #, left=np.nan, right=np.nan)
    new_data = interpolator(new_x)
    return new_data

################################################################################
# Load data of emulsions
################################################################################

def load_csv(datapkg, filename):
    """
    Load data from a CSV file and return it as a transposed NumPy array.

    Parameters:
    filename (str): The path to the CSV file to be loaded.

    Returns:
    numpy.ndarray: A transposed NumPy array containing the data from the CSV file.
                   Empty elements in the CSV are converted to None.
    """
    conv = lambda x: float(x) if x!=b'' else None # conversion function to take care of empty elements
    package = pkg_resources.files(datapkg)
    resource = package / filename
    raw_data = np.loadtxt(resource, delimiter=',', converters=conv).transpose()
    return raw_data

def load_agx_emulsion_data(stock='kodak_portra_400',
                           log_sensitivity_donor=None,
                           denisty_curves_donor=None,
                           dye_density_cmy_donor=None,
                           dye_density_min_mid_donor=None,
                           type='negative',
                           color=True,
                           spectral_shape=SPECTRAL_SHAPE,
                           log_exposure=LOG_EXPOSURE,
                           ):
    if    color and type=='negative': maindatapkg = "agx_emulsion.data.film.negative"
    elif  color and type=='positive': maindatapkg = "agx_emulsion.data.film.positive"
    elif  color and type=='paper':    maindatapkg = "agx_emulsion.data.paper"
    
    # Load log sensitivity
    if log_sensitivity_donor is not None: datapkg = maindatapkg + '.' + log_sensitivity_donor
    else:                                 datapkg = maindatapkg + '.' + stock
    rootname = 'log_sensitivity_'
    log_sensitivity = np.zeros((np.size(spectral_shape.wavelengths), 3))
    channels = ['r', 'g', 'b']
    for i, channel in enumerate(channels):
        data = load_csv(datapkg, rootname+channel+'.csv')
        log_sens = interpolate_to_common_axis(data, spectral_shape.wavelengths)
        log_sensitivity[:,i] = log_sens

    # Load density curves
    if denisty_curves_donor is not None: datapkg = maindatapkg + '.' + denisty_curves_donor
    else:                                datapkg = maindatapkg + '.' + stock
    filename_r = 'density_curve_r.csv'
    filename_g = 'density_curve_g.csv'
    filename_b = 'density_curve_b.csv'
    dh_curve_r = load_csv(datapkg, filename_r)
    dh_curve_g = load_csv(datapkg, filename_g)
    dh_curve_b = load_csv(datapkg, filename_b)
    log_exposure_shift = (np.max(dh_curve_g[0,:]) + np.min(dh_curve_g[0,:]))/2
    p_denc_r = interpolate_to_common_axis(dh_curve_r, log_exposure + log_exposure_shift)
    p_denc_g = interpolate_to_common_axis(dh_curve_g, log_exposure + log_exposure_shift)
    p_denc_b = interpolate_to_common_axis(dh_curve_b, log_exposure + log_exposure_shift)
    density_curves = np.array([p_denc_r, p_denc_g, p_denc_b]).transpose()

    # Load dye density
    if dye_density_cmy_donor is not None: datapkg = maindatapkg + '.' + dye_density_cmy_donor
    else:                                 datapkg = maindatapkg + '.' + stock
    rootname = 'dye_density_'
    dye_density = np.zeros((np.size(spectral_shape.wavelengths), 5))
    channels = ['c', 'm', 'y']
    for i, channel in enumerate(channels):
        data = load_csv(datapkg, rootname+channel+'.csv')
        dye_density[:,i] = interpolate_to_common_axis(data, spectral_shape.wavelengths)
    if dye_density_min_mid_donor is not None: datapkg = maindatapkg + '.' + dye_density_min_mid_donor
    else:                                     datapkg = maindatapkg + '.' + stock
    if type=='negative':
        channels = ['min', 'mid']
        for i, channel in enumerate(channels):
            data = load_csv(datapkg, rootname+channel+'.csv')
            dye_density[:,i+3] = interpolate_to_common_axis(data, spectral_shape.wavelengths)

    return log_sensitivity, dye_density, spectral_shape.wavelengths, density_curves, log_exposure

def load_densitometer_data(type='status_A',
                           spectral_shape=SPECTRAL_SHAPE):
    responsivities = np.zeros((np.size(spectral_shape.wavelengths), 3))
    channels = ['r', 'g', 'b']
    for i, channel in enumerate(channels):
        datapkg = 'agx_emulsion.data.densitometer.'+type
        filename = 'responsivity_'+channel+'.csv'
        data = load_csv(datapkg, filename)
        responsivities[:,i] = interpolate_to_common_axis(data, spectral_shape.wavelengths, extrapolate=False, method='linear')
    responsivities[responsivities<0] = 0
    responsivities /= np.nansum(responsivities, axis=0)
    return responsivities


################################################################################
# YMC filter values
################################################################################

def save_ymc_filter_values(ymc_filters):
    # to be launched only in the package not accessible by the user
    package = pkg_resources.files('agx_emulsion.data.profiles')
    filename = 'enlarger_neutral_ymc_filters.json'
    resource = package / filename
    with resource.open("w") as file:
        json.dump(ymc_filters, file, indent=4)

def read_neutral_ymc_filter_values():
    filename = 'enlarger_neutral_ymc_filters.json'
    package_name = 'agx_emulsion.data.profiles'
    package = pkg_resources.files(package_name)
    resource = package / filename
    with resource.open("r") as file:
        ymc_filters = json.load(file)
    return ymc_filters

################################################################################
# Profiles
################################################################################

def load_dichroic_filters(wavelengths, brand='thorlabs'):
    channels = ['y','m','c']
    filters = np.zeros((np.size(wavelengths), 3))
    for i, channel in enumerate(channels):
        package = pkg_resources.files('agx_emulsion.data.filters.dichroics')
        filename = brand+'/filter_'+channel+'.csv'
        resource = package / filename
        with resource.open("r") as file:
            data = np.loadtxt(file, delimiter=',')
            filters[:,i] = scipy.interpolate.CubicSpline(data[:,0], data[:,1]/100)(wavelengths)
    return filters

if __name__ == '__main__':
    # imageio.plugins.freeimage.download()
    # img = read_png_16bit('img/targets/cc_halation.png')

    load_agx_emulsion_data()
    read_neutral_ymc_filter_values()
    # load_densitometer_data()
    
    
    