import numpy as np
import struct
import colour
import scipy
import importlib.resources
from opt_einsum import contract
import scipy.interpolate
from agx_emulsion.utils.fast_interp_lut3d import apply_lut_cubic
from agx_emulsion.config import SPECTRAL_SHAPE

################################################################################
# LUT generatation of irradiance spectra for any xy chromaticity
# Thanks to hanatos for providing luts and sample code to develop this. I am grateful.

def load_coeffs_lut(filename='hanatos_irradiance_xy_coeffs_250221.lut'):
    # load lut of coefficients for efficient computations of irradiance spectra
    # formatting
    header_fmt = '=4i'
    header_len = struct.calcsize(header_fmt)
    pixel_fmt = '=4f'
    pixel_len = struct.calcsize(pixel_fmt)

    package = importlib.resources.files('agx_emulsion.data.luts.spectral_upsampling')
    resource = package / filename
    with resource.open("rb") as file:
        header = file.read(header_len)
        h = struct.Struct(header_fmt).unpack_from(header)
        px = [[0] * h[2] for _ in range(h[3])]
        for j in range(0,h[3]):
            for i in range(0,h[2]):
                data = file.read(pixel_len)
                px[i][j] = struct.Struct(pixel_fmt).unpack_from(data)
        px = np.array(px)
    px = np.array(px)
    return px

def tri2quad(tc):
    # converts triangular coordinates into square coordinates.
    # for better sampling of the visible locus of xy chromaticities.
    tc = np.array(tc)
    x = tc[...,0]
    y = tc[...,1]
    y = y / (1.0 - x)
    x = (1.0 - x)*(1.0 - x)
    x = np.clip(x, 0, 1)
    y = np.clip(y, 0, 1)
    return np.stack((x,y), axis=-1)

def fetch_coeffs(rgb, lut_coeffs, color_space='ITU-R BT.2020', apply_cctf_decoding=False):
    # find the coefficients for spectral upsampling of given rgb coordinates
    if color_space!='ITU-R BT.2020' or apply_cctf_decoding:
        rgb = colour.RGB_to_RGB(rgb, input_colourspace=color_space, apply_cctf_decoding=apply_cctf_decoding,
                                        output_colourspace='ITU-R BT.2020', apply_cctf_encoding=False)
        rgb = np.clip(rgb,0,1)
    xyz = colour.RGB_to_XYZ(rgb, colourspace='ITU-R BT.2020', apply_cctf_decoding=False)
    b = np.sum(xyz, axis=-1)
    xy = xyz[...,0:2] / b[...,None]
    tc = tri2quad(xy)
    coeffs = np.zeros(np.concatenate((b.shape,[4])))
    h = 1/(np.array(lut_coeffs.shape[:2])-1)
    x = np.linspace(0,1,lut_coeffs.shape[0])
    for i in np.arange(4):
        coeffs[...,i] = scipy.interpolate.RegularGridInterpolator((x,x), lut_coeffs[:,:,i], method='cubic')(tc)
    return coeffs[...,:3], b/coeffs[...,3]

def compute_spectra_from_coeffs(coeffs, b, smooth_steps=1):
    wl = SPECTRAL_SHAPE.wavelengths
    wl_up = np.linspace(360,800,881) # upsampled wl for finer initial calculation 0.5 nm
    x = (coeffs[...,0,None] * wl_up + coeffs[...,1,None])*  wl_up  + coeffs[...,2,None]
    y = 1.0 / np.sqrt(x * x + 1.0)
    spectra = 0.5 * x * y +  0.5
    spectra *= b[...,None]
    
    # smooth of half step sigma and downsample
    step = np.mean(np.diff(wl))
    spectra = scipy.ndimage.gaussian_filter(spectra, step*smooth_steps, axes=-1)
    def interp_slice(a, wl, wl_up):
        return np.interp(wl, wl_up, a)
    spectra = np.apply_along_axis(interp_slice, axis=-1, wl=wl, wl_up=wl_up, arr=spectra)
    return spectra

def compute_lut(lut_size=32, color_space='ITU-R BT.2020', smooth_steps=0.5):
    lut_coeffs = load_coeffs_lut()
    x = np.linspace(0,1,lut_size)
    r,g,b = np.meshgrid(x,x,x)
    rgb_lut = np.stack((g,r,b), axis=-1)
    rgb_lut[0,0,0] = [1,1,1]

    coeffs, b = fetch_coeffs(rgb_lut, lut_coeffs, color_space=color_space, apply_cctf_decoding=False)
    coeffs[0,0,0] = [0,0,0]
    b[0,0,0] = 0
    lut_spectra = compute_spectra_from_coeffs(coeffs, b, smooth_steps=smooth_steps)
    lut_spectra = np.array(lut_spectra, dtype=np.half)
    return lut_spectra

################################################################################
# Band pass filter

def sigmoid_erf(x, center, width=1):
    return scipy.special.erf((x-center)/width)*0.5+0.5
def compute_band_pass_filter(filter_uv=[1, 410, 8], filter_ir=[1, 675, 15]):
    amp_uv = filter_uv[0]
    wl_uv = filter_uv[1]
    width_uv = filter_uv[2]
    
    amp_ir = filter_ir[0]
    wl_ir = filter_ir[1]
    width_ir = filter_ir[2]
    
    amp_uv = np.clip(amp_uv, 0, 1)
    amp_ir = np.clip(amp_ir, 0, 1)
    
    wl = SPECTRAL_SHAPE.wavelengths
    filter_uv  = 1-amp_uv + amp_uv*sigmoid_erf(wl, wl_uv, width=width_uv)
    filter_ir  = 1-amp_ir + amp_ir*sigmoid_erf(wl, wl_ir, width=-width_ir)
    band_pass_filter = filter_uv * filter_ir
    return  band_pass_filter

################################################################################
# From [Mallett2019]

MALLETT2019_BASIS = colour.recovery.MSDS_BASIS_FUNCTIONS_sRGB_MALLETT2019.copy().align(SPECTRAL_SHAPE)
def rgb_to_raw_mallett2019(RGB, illuminant, sensitivity,
                           color_space='sRGB', apply_cctf_decoding=True,
                           band_pass_filter=None):
    """
    Converts an RGB color to a raw sensor response using the method described in Mallett et al. (2019).

    Parameters
    ----------
    RGB : array_like
        RGB color values.
    illuminant : array_like
        Illuminant spectral distribution.
    sensitivity : array_like
        Camera sensor spectral sensitivities.
    color_space : str, optional
        The color space of the input RGB values. Default is 'sRGB'.
    apply_cctf_decoding : bool, optional
        Whether to apply the color component transfer function (CCTF) decoding. Default is True.

    Returns
    -------
    raw : ndarray
        Raw sensor response.
    """
    if band_pass_filter is not None:
        sensitivity *= band_pass_filter[:,None]
    basis_set_with_illuminant = np.array(MALLETT2019_BASIS[:])*np.array(illuminant)[:, None]
    lrgb = colour.RGB_to_RGB(RGB, color_space, 'sRGB',
                    apply_cctf_decoding=apply_cctf_decoding,
                    apply_cctf_encoding=False)
    lrgb = np.clip(lrgb, 0, None)
    raw  = contract('ijk,lk,lm->ijm', lrgb, basis_set_with_illuminant, sensitivity)
    raw = np.nan_to_num(raw)
    raw = np.ascontiguousarray(raw)
    
    raw_midgray  = np.einsum('k,km->m', illuminant*0.184, sensitivity) # use 0.184 as midgray reference
    return raw / raw_midgray[1] # normalize with green channel

################################################################################
# Using hanatos irradiance spectra generation

def rgb_to_raw_hanatos2025(rgb, sensitivity,
                           color_space, apply_cctf_decoding,
                           band_pass_filter=None):
    if band_pass_filter is not None:
        sensitivity *= band_pass_filter[:,None]
    # get spectra lut, approx 2 milliseconds
    data_path = importlib.resources.files('agx_emulsion.data.luts.spectral_upsampling').joinpath('irradiance_rec2020_32size.npy')
    with data_path.open('rb') as file:
        spectra_lut = np.double(np.load(file))
    raw_lut  = contract('ijkl,lm->ijkm', spectra_lut, sensitivity)
    h = 1/(spectra_lut.shape[0]-1) # lut_step

    # spectra lut is in linear rec2020
    rgb = colour.RGB_to_RGB(rgb, 
                            input_colourspace=color_space, 
                            output_colourspace='ITU-R BT.2020',
                            apply_cctf_decoding=apply_cctf_decoding,
                            apply_cctf_encoding=False)
    rgb = np.clip(rgb, 0, None) # clip negatives, eg when ACES2065-1 >> rec2020
    rgb_scale = np.max(rgb, axis=-1) # scale rgb by the max to be able to be interp with the lut
    rgb /= rgb_scale[...,None]
    rgb = np.nan_to_num(rgb) # temporary for safety, fix divide by zero
    raw = np.zeros_like(rgb)
    raw = apply_lut_cubic(raw_lut, rgb)
    raw *= rgb_scale[...,None] # scale the raw back with the scale factor
    # raw = np.nan_to_num(raw) # make sure nans are removed
    
    illuminant = spectra_lut[-1,-1,-1]
    raw_midgray  = np.einsum('k,km->m', illuminant*0.184, sensitivity) # use 0.184 as midgray reference
    return raw / raw_midgray[1] # normalize with green channel

if __name__=='__main__':
    lut_coeffs = load_coeffs_lut()
    coeffs, b = fetch_coeffs(np.array([[1,1,1]]) ,lut_coeffs)
    spectra = compute_spectra_from_coeffs(coeffs, b)
    lut_spectra = compute_lut(lut_size=32, color_space='ITU-R BT.2020')