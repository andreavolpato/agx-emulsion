import numpy as np
import colour
from opt_einsum import contract

from agx_emulsion.config import SPECTRAL_SHAPE
from agx_emulsion.utils.io import load_densitometer_data

def density_to_light(density, light):
    """
    Convert density to light transmittance.

    This function calculates the light transmittance based on the given density
    and light intensity. It uses the formula transmittance = 10^(-density) to 
    compute the transmittance and then multiplies it by the light intensity.

    Parameters:
    density (float or np.ndarray): The density value(s) which affect the light transmittance.
    light (float or np.ndarray): The initial light intensity value(s).

    Returns:
    np.ndarray: The light intensity after passing through the medium with the given density.
    """
    transmitted = 10**(-density)
    transmitted *= light
    transmitted[np.isnan(transmitted)] = 0
    return transmitted

def compute_densitometer_correction(dye_density, type='status_A'):
    densitometer_responsivities = load_densitometer_data(type=type)
    dye_density = dye_density[:,0:3]
    dye_density[np.isnan(dye_density)] = 0
    densitometer_correction = 1/np.sum(densitometer_responsivities[:] * dye_density, axis=0)
    return densitometer_correction

def compute_aces_conversion_matrix(sensitivity, illuminant):            
    """
    Computes the ACES (Academy Color Encoding System) conversion matrix.

    Parameters
    ----------
    sensitivity : array-like
        The spectral sensitivity data.
    illuminant : array-like
        The illuminant spectral distribution.

    Returns
    -------
    numpy.ndarray
        The ACES to raw conversion matrix.
    """
    msds = colour.MultiSpectralDistributions(sensitivity, domain=SPECTRAL_SHAPE.wavelengths)
    M, _ = colour.matrix_idt(msds, illuminant)
    aces_to_raw_conversion_matrix = np.linalg.inv(M)
    return aces_to_raw_conversion_matrix

def rgb_to_raw_aces_idt(RGB, illuminant, sensitivity, midgray_rgb=[[[0.184,0.184,0.184]]],
                        color_space='sRGB', apply_cctf_decoding=True, aces_conversion_matrix=[]):
    """
    Converts RGB values to raw values using ACES IDT (Input Device Transform).

    Parameters:
    RGB (array-like): The input RGB values.
    illuminant (array-like): The illuminant data.
    sensitivity (array-like): The sensitivity data.
    midgray_rgb (array-like, optional): The mid-gray RGB values. Default is [[[0.184, 0.184, 0.184]]].
    color_space (str, optional): The color space of the input RGB values. Default is 'sRGB'.
    apply_cctf_decoding (bool, optional): Whether to apply the CCTF decoding. Default is True.
    aces_conversion_matrix (array-like, optional): The ACES conversion matrix. Default is an empty list.

    Returns:
    tuple: A tuple containing:
        - raw (array-like): The raw values.
        - raw_midgray (array-like): The raw mid-gray values.
    """
    aces = colour.RGB_to_RGB(RGB, color_space, 'ACES2065-1',
                    apply_cctf_decoding=apply_cctf_decoding,
                    apply_cctf_encoding=False)
    if aces_conversion_matrix==[]:
        aces_conversion_matrix = compute_aces_conversion_matrix(sensitivity, illuminant)
    raw = contract('ijk,lk->ijl',aces,aces_conversion_matrix)/midgray_rgb
    raw_midgray = np.array([[[1,1,1]]])
    return raw, raw_midgray
