import numpy as np
import struct
import colour
import scipy
import importlib.resources
from opt_einsum import contract
import scipy.interpolate
from agx_emulsion.utils.fast_interp_lut import apply_lut_cubic_2d
from agx_emulsion.config import SPECTRAL_SHAPE, STANDARD_OBSERVER_CMFS
from agx_emulsion.model.illuminants import standard_illuminant

################################################################################
# LUT generatation of irradiance spectra for any xy chromaticity
# Thanks to hanatos for providing luts and sample code to develop this. I am grateful.

def load_coeffs_lut(filename='hanatos_irradiance_xy_coeffs_250304.lut'):
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
    # the lut is represented in triangular coordinates
    tc = np.array(tc)
    tx = tc[...,0]
    ty = tc[...,1]
    y = ty / np.fmax(1.0 - tx, 1e-10)
    x = (1.0 - tx)*(1.0 - tx)
    x = np.clip(x, 0, 1)
    y = np.clip(y, 0, 1)
    return np.stack((x,y), axis=-1)

def quad2tri(xy):
    # converts square coordinates into triangular coordinates
    x = xy[...,0]
    y = xy[...,1]
    tx = 1 - np.sqrt(x)
    ty = y * np.sqrt(x)
    return np.stack((tx,ty), axis=-1)

def fetch_coeffs(tc, lut_coeffs):
    # find the coefficients for spectral upsampling of given rgb coordinates
    # if color_space!='ITU-R BT.2020' or apply_cctf_decoding:
    #     rgb = colour.RGB_to_RGB(rgb, input_colourspace=color_space, apply_cctf_decoding=apply_cctf_decoding,
    #                                     output_colourspace='ITU-R BT.2020', apply_cctf_encoding=False)
    #     rgb = np.clip(rgb,0,1)
    # xyz = colour.RGB_to_XYZ(rgb, colourspace='ITU-R BT.2020', apply_cctf_decoding=False)
    # b = np.sum(xyz, axis=-1)
    # xy = xyz[...,0:2] / b[...,None]
    # tc = tri2quad(xy)
    coeffs = np.zeros(np.concatenate((tc.shape[:-1],[4])))
    # h = 1/(np.array(lut_coeffs.shape[:2])-1)
    x = np.linspace(0,1,lut_coeffs.shape[0])
    for i in np.arange(4):
        coeffs[...,i] = scipy.interpolate.RegularGridInterpolator((x,x), lut_coeffs[:,:,i], method='cubic')(tc)
    return coeffs

def compute_spectra_from_coeffs(coeffs, smooth_steps=1):
    wl = SPECTRAL_SHAPE.wavelengths
    wl_up = np.linspace(360,800,441) # upsampled wl for finer initial calculation 0.5 nm
    x = (coeffs[...,0,None] * wl_up + coeffs[...,1,None])*  wl_up  + coeffs[...,2,None]
    y = 1.0 / np.sqrt(x * x + 1.0)
    spectra = 0.5 * x * y +  0.5
    spectra /= coeffs[...,3][...,None]
    
    # gaussian smooth with smooth_step*sigmas and downsample
    step = np.mean(np.diff(wl))
    spectra = scipy.ndimage.gaussian_filter(spectra, step*smooth_steps, axes=-1)
    def interp_slice(a, wl, wl_up):
        return np.interp(wl, wl_up, a)
    spectra = np.apply_along_axis(interp_slice, axis=-1, wl=wl, wl_up=wl_up, arr=spectra)
    return spectra

def compute_lut_spectra(lut_size=128, smooth_steps=1, lut_coeffs_filename='hanatos_irradiance_xy_coeffs_250304.lut'):
    v = np.linspace(0,1,lut_size)
    tx,ty = np.meshgrid(v,v, indexing='ij')
    tc = np.stack((tx,ty), axis=-1)
    lut_coeffs = load_coeffs_lut(lut_coeffs_filename)
    coeffs = fetch_coeffs(tc, lut_coeffs)
    lut_spectra = compute_spectra_from_coeffs(coeffs, smooth_steps=smooth_steps)
    lut_spectra = np.array(lut_spectra, dtype=np.half)
    return lut_spectra

def load_spectra_lut(filename='irradiance_xy_tc.npy'):
    data_path = importlib.resources.files('agx_emulsion.data.luts.spectral_upsampling').joinpath(filename)
    with data_path.open('rb') as file:
        spectra_lut = np.double(np.load(file))
    return spectra_lut

def illuminant_to_xy(illuminant_label):
    illu = standard_illuminant(illuminant_label)
    xyz = np.zeros((3))
    for i in np.arange(3):
        xyz[i] = np.sum(illu * STANDARD_OBSERVER_CMFS[:][:,i])
    xy = xyz[0:2] / np.sum(xyz)
    return xy

def rgb_to_tc_b(rgb, color_space='ITU-R BT.2020', apply_cctf_decoding=False, reference_illuminant='D55'):
    # source_cs = colour.RGB_COLOURSPACES[color_space]
    # target_cs = source_cs.copy()
    # target_cs.whitepoint = ILLUMINANTS['CIE 1931 2 Degree Standard Observer']['D65']
    # adapted_rgb = colour.RGB_to_RGB(rgb, input_colourspace=source_cs,
    #                                 output_colourspace=target_cs,
    #                                 adaptation_transform='Bradford')    
    # illu_xy = colour.CCS_ILLUMINANTS['CIE 1931 2 Degree Standard Observer'][reference_illuminant]
    illu_xy = illuminant_to_xy(reference_illuminant)
    xyz = colour.RGB_to_XYZ(rgb, colourspace=color_space,
                            apply_cctf_decoding=apply_cctf_decoding,
                            illuminant=illu_xy,
                            chromatic_adaptation_transform='CAT02')
    b = np.sum(xyz, axis=-1)
    xy = xyz[...,0:2] / np.fmax(b[...,None], 1e-10)
    xy = np.clip(xy,0,1)
    tc = tri2quad(xy)
    b = np.nan_to_num(b)
    return tc, b

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
def rgb_to_raw_mallett2019(RGB, sensitivity,
                           color_space='sRGB', apply_cctf_decoding=True,
                           reference_illuminant='D65'):
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
    illuminant = standard_illuminant(reference_illuminant)[:]
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

HANATOS2025_SPECTRA_LUT = load_spectra_lut()

def rgb_to_raw_hanatos2025(rgb, sensitivity,
                           color_space, apply_cctf_decoding, reference_illuminant):
    if rgb.shape[1] == 1: # if a single pixel is provided, compute the spectrum directly
        spectrum = rgb_to_spectrum(rgb,
                                   color_space=color_space,
                                   apply_cctf_decoding=apply_cctf_decoding,
                                   reference_illuminant=reference_illuminant)
        raw = np.einsum('l,lm->m', spectrum, sensitivity)
        raw = np.array([[raw]])
    else:
        tc_raw, b = rgb_to_tc_b(rgb, color_space=color_space, apply_cctf_decoding=apply_cctf_decoding, 
                                reference_illuminant=reference_illuminant)
        tc_lut  = contract('ijl,lm->ijm', HANATOS2025_SPECTRA_LUT, sensitivity)
        raw = apply_lut_cubic_2d(tc_lut, tc_raw)
        raw *= b[...,None] # scale the raw back with the scale factor
    
    midgray_rgb = np.array([[[0.184]*3]])
    illuminant_midgray = rgb_to_spectrum(midgray_rgb, color_space=color_space, apply_cctf_decoding=False, reference_illuminant=reference_illuminant)
    raw_midgray  = np.einsum('k,km->m', illuminant_midgray, sensitivity) # use 0.184 as midgray reference
    return raw / raw_midgray[1] # normalize with green channel

def rgb_to_spectrum(rgb, color_space, apply_cctf_decoding, reference_illuminant):
    # direct interpolation of the spectra lut, to be used only for smooth spectra close to white
    tc_w, b_w = rgb_to_tc_b(rgb,
                            color_space=color_space,
                            apply_cctf_decoding=apply_cctf_decoding,
                            reference_illuminant=reference_illuminant)
    # spectrum_w = apply_lut_cubic_2d(spectra_lut, tc_w)
    v = np.linspace(0, 1, HANATOS2025_SPECTRA_LUT.shape[0])
    spectrum_w = scipy.interpolate.RegularGridInterpolator((v,v), HANATOS2025_SPECTRA_LUT)(tc_w)
    spectrum_w *= b_w
    return spectrum_w.flatten()

if __name__=='__main__':
    lut_coeffs = load_coeffs_lut()
    coeffs = fetch_coeffs(np.array([[1,1]]) ,lut_coeffs)
    spectra = compute_spectra_from_coeffs(coeffs)
    lut_spectra = compute_lut_spectra(lut_size=128)
    