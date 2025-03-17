import numpy as np
import scipy.interpolate
import json
import OpenImageIO as oiio
import importlib.resources as pkg_resources

from agx_emulsion.config import LOG_EXPOSURE, SPECTRAL_SHAPE

################################################################################
# 16-bit PNG I/O
################################################################################

def load_image_oiio(filename):
    # Open the image file
    in_img = oiio.ImageInput.open(filename)
    if not in_img:
        raise IOError("Could not open image file: " + filename)
    
    try:
        spec = in_img.spec()
        
        # Determine the native pixel format:
        # Use "uint16" for PNG and "half" for EXR if applicable.
        if spec.format == oiio.TypeDesc("uint8"): # for compatibility
            read_type = oiio.TypeDesc("uint8")
        elif spec.format == oiio.TypeDesc("uint16"):
            read_type = oiio.TypeDesc("uint16")
        elif spec.format == oiio.TypeDesc("half"):
            read_type = oiio.TypeDesc("half")
        elif spec.format == oiio.TypeDesc("float"):
            read_type = oiio.TypeDesc("float")
        else:
            # Fallback: use "uint16" by default. You might choose "float" if desired.
            read_type = oiio.TypeDesc("uint16")
        
        # Read the image data using the chosen type
        pixels = in_img.read_image(read_type)
        if pixels is None:
            raise Exception("Failed to read image data from " + filename)
        
        # Convert the raw data to a NumPy array and reshape it
        np_pixels = np.array(pixels)
        np_pixels = np_pixels.reshape(spec.height, spec.width, spec.nchannels)
        
        if spec.format == oiio.TypeDesc("uint16"):
            np_pixels = np.double(np_pixels)/(2**16-1)
        if spec.format == oiio.TypeDesc("uint8"):
            np_pixels = np.double(np_pixels)/(2**8-1)
        
        return np_pixels
    finally:
        in_img.close()

def save_image_oiio(filename, image_data, bit_depth=32):
    """
    Save a floating-point (double) image with 3 channels as a 16-bit image file.
    For PNG files, the image data is scaled to the [0,65535] range and saved as uint16.
    For EXR files, the image data is converted to 16-bit half floats.
    
    Parameters:
      filename (str): The output file name (e.g., "saved_image.png" or "saved_image.exr")
      image_data (np.ndarray): The input image data as a NumPy array with shape (height, width, 3).
    """
    # Extract image dimensions and number of channels
    height, width, nchannels = image_data.shape

    # Determine file type based on extension
    ext = filename.split('.')[-1].lower()
    
    # Create an ImageSpec with the proper data type
    if ext == "png":
        # Assume image_data is in [0, 1]: scale to 16-bit unsigned integers.
        img_uint16 = np.clip(image_data, 0, 1) * 65535.0
        img_uint16 = img_uint16.astype(np.uint16)
        spec = oiio.ImageSpec(width, height, nchannels, oiio.TypeDesc("uint16"))
        data_to_write = img_uint16
    elif ext=="exr" and bit_depth==16:
        # Convert the image data to 16-bit half precision.
        # Note: numpy's float16 is used here; OpenImageIO accepts "half" for 16-bit floats.
        img_half = image_data.astype(np.float16)
        spec = oiio.ImageSpec(width, height, nchannels, oiio.TypeDesc("half"))
        data_to_write = img_half
    elif ext=='exr' and bit_depth==32:
        # Convert the image data to 16-bit half precision.
        # Note: numpy's float16 is used here; OpenImageIO accepts "half" for 16-bit floats.
        img_float = image_data.astype(np.float32)
        spec = oiio.ImageSpec(width, height, nchannels, oiio.TypeDesc("float"))
        data_to_write = img_float
    else:
        raise ValueError("Unsupported file extension: " + ext)
    
    # Create an ImageOutput for writing the file
    out = oiio.ImageOutput.create(filename)
    if not out:
        raise IOError("Could not create output image: " + filename)
    
    try:
        out.open(filename, spec)
        # Write the image data; write_image accepts the NumPy array directly.
        out.write_image(data_to_write)
    finally:
        out.close()

################################################################################
# Interpolation
################################################################################

def interpolate_to_common_axis(data, new_x,
                               extrapolate=False, method='akima'):
    x = data[0]
    y = data[1]
    sorted_indexes = np.argsort(x)
    x = x[sorted_indexes]
    y = y[sorted_indexes]
    unique_index = np.unique(x, return_index=True)[1]
    x = x[unique_index]
    y = y[unique_index]
    if method=='cubic':
        interpolator = scipy.interpolate.CubicSpline(x, y, extrapolate=extrapolate)
    if method=='akima':
        interpolator = scipy.interpolate.Akima1DInterpolator(x, y, extrapolate=extrapolate)
    elif method=='linear':
        def interpolator(x_new):
            return np.interp(x_new, x, y) #, left=np.nan, right=np.nan)
    elif method=='smoothing_spline':
        interpolator = scipy.interpolate.make_smoothing_spline(x, y)
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
                           log_exposure=np.copy(LOG_EXPOSURE),
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
            unique_index = np.unique(data[:,0], return_index=True)[1]
            data = data[unique_index,:]
            # filters[:,i] = scipy.interpolate.CubicSpline(data[:,0], data[:,1]/100)(wavelengths)
            filters[:,i] = scipy.interpolate.Akima1DInterpolator(data[:,0], data[:,1]/100)(wavelengths)
    return filters

def load_filter(wavelengths, name='KG3', brand='schott', filter_type='heat_absorbing', percent_transmittance=False):
    transmittance = np.zeros_like(wavelengths)
    package = pkg_resources.files('agx_emulsion.data.filters.'+filter_type)
    filename = brand+'/'+name+'.csv'
    resource = package / filename
    if percent_transmittance: scale = 100
    else: scale = 1
    with resource.open("r") as file:
        data = np.loadtxt(file, delimiter=',')
        unique_index = np.unique(data[:,0], return_index=True)[1]
        data = data[unique_index,:]
        # transmittance = scipy.interpolate.CubicSpline(data[:,0], data[:,1]/scale)(wavelengths)
        transmittance = scipy.interpolate.Akima1DInterpolator(data[:,0], data[:,1]/scale)(wavelengths)
    return transmittance

if __name__ == '__main__':
    import matplotlib.pyplot as plt
    # load_agx_emulsion_data()
    # read_neutral_ymc_filter_values()
    # load_densitometer_data()
    kg3 = load_filter(SPECTRAL_SHAPE.wavelengths)
    plt.plot(SPECTRAL_SHAPE.wavelengths, kg3)
    plt.show()
    