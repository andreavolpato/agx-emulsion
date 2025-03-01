import numpy as np
import copy
import colour
from dotmap import DotMap
from opt_einsum import contract
import skimage.transform

from agx_emulsion.config import ENLARGER_STEPS, STANDARD_OBSERVER_CMFS
from agx_emulsion.model.emulsion import Film, compute_density_spectral, develop_simple, compute_random_glare_amount
from agx_emulsion.utils.autoexposure import measure_autoexposure_ev
from agx_emulsion.utils.conversions import density_to_light
from agx_emulsion.utils.spectral_upsampling import rgb_to_raw_mallett2019, rgb_to_raw_hanatos2025, compute_band_pass_filter
from agx_emulsion.utils.lut import compute_with_lut
from agx_emulsion.model.diffusion import apply_gaussian_blur_um, apply_halation_um, apply_unsharp_mask, apply_gaussian_blur
from agx_emulsion.model.color_filters import color_enlarger
from agx_emulsion.utils.crop_resize import crop_image
from agx_emulsion.model.illuminants import standard_illuminant
from agx_emulsion.utils.io import read_neutral_ymc_filter_values
from agx_emulsion.profiles.io import load_profile
from agx_emulsion.utils.timings import timeit, plot_timings

ymc_filters = read_neutral_ymc_filter_values()

def photo_params(negative='kodak_vision3_50d_uc',
                 print_paper='kodak_portra_endura_uc',
                 ymc_filters_from_database=True):
    params = DotMap()
    params.negative = load_profile(negative)
    params.print_paper = load_profile(print_paper)
    params.camera = DotMap()
    params.enlarger = DotMap()
    params.scanner = DotMap()
    params.io = DotMap()
    
    params.camera.exposure_compensation_ev = 0.0
    params.camera.auto_exposure = True
    params.camera.auto_exposure_method = 'center_weighted'
    params.camera.lens_blur_um = 0.0 # about 5 um sigma for typical lenses, down to 2-4 um for high quality lenses, used for sharp simulations without lens blur.
    params.camera.film_format_mm = 35.0
    params.camera.filter_uv = (1, 410, 8)
    params.camera.filter_ir = (1, 675, 15)
    
    params.enlarger.illuminant = 'BB3200'
    params.enlarger.print_exposure = 1.0
    params.enlarger.print_exposure_compensation = True
    params.enlarger.y_filter_shift = 0.0
    params.enlarger.m_filter_shift = 0.0
    if ymc_filters_from_database:
        params.enlarger.y_filter_neutral = ymc_filters[print_paper][params.enlarger.illuminant][negative][0]
        params.enlarger.m_filter_neutral = ymc_filters[print_paper][params.enlarger.illuminant][negative][1]
        params.enlarger.c_filter_neutral = ymc_filters[print_paper][params.enlarger.illuminant][negative][2]
    else:
        params.enlarger.y_filter_neutral = 0.6
        params.enlarger.m_filter_neutral = 0.4
        params.enlarger.c_filter_neutral = 0.35
    params.enlarger.lens_blur = 0.0
    params.enlarger.preflash_exposure = 0.0
    params.enlarger.preflash_y_filter_shift = 0.0
    params.enlarger.preflash_m_filter_shift = 0.0
    params.enlarger.just_preflash = False
    
    params.scanner.lens_blur = 0.55
    params.scanner.unsharp_mask = (0.7,1.0)

    params.io.input_color_space = 'ProPhoto RGB'
    params.io.input_cctf_decoding = False
    params.io.output_color_space = 'sRGB'
    params.io.output_cctf_encoding = True
    params.io.crop = False
    params.io.crop_center = (0.5,0.5)
    params.io.crop_size = (0.1, 1.0)
    params.io.preview_resize_factor = 1.0
    params.io.upscale_factor = 1.0
    params.io.full_image = False
    params.io.compute_negative = False
    params.io.compute_film_raw = False
    
    params.debug.deactivate_spatial_effects = False
    params.debug.deactivate_stochastic_effects = False
    params.debug.input_negative_density_cmy = False
    params.debug.return_negative_density_cmy = False
    params.debug.return_print_density_cmy = False
    params.debug.print_timings = False
    
    params.settings.rgb_to_raw_method = 'hanatos2025'
    params.settings.use_camera_lut = False
    params.settings.use_enlarger_lut = False
    params.settings.use_scanner_lut = False
    params.settings.lut_resolution = 32
    params.settings.use_fast_stats = False
    
    return params

class AgXPhoto():
    def __init__(self, params):
        self._params = copy.deepcopy(params)
        # main components
        self.camera = params.camera
        self.negative = params.negative
        self.enlarger = params.enlarger
        self.print_paper = params.print_paper
        self.scanner = params.scanner
        # auxiliary and special
        self.io = params.io
        self.debug = params.debug
        self.settings = params.settings
        self.timings = {} # dictionary to hold timing info
        self._apply_debug_switches()

    def _apply_debug_switches(self):
        if self.debug.deactivate_spatial_effects:
            self.negative.halation.size_um = [0,0,0]
            self.negative.halation.scattering_size_um = [0,0,0]
            self.negative.dir_couplers.diffusion_size_um = 0
            self.negative.grain.blur = 0.0
            self.negative.grain.blur_dye_clouds_um = 0.0
            self.print_paper.glare.blur = 0
            self.camera.lens_blur_um = 0.0
            self.enlarger.lens_blur = 0.0
            self.scanner.lens_blur = 0.0
            self.scanner.unsharp_mask = (0.0, 0.0)

        if self.debug.deactivate_stochastic_effects:
            self.negative.grain.active = False
            self.negative.glare.active = False
            self.print_paper.glare.active = False

    def process(self, image):
        image = np.double(np.array(image)[:,:,0:3])
        
        # input
        exposure_ev = self._auto_exposure(image)
        image, preview_resize_factor, pixel_size_um = self._crop_and_rescale(image)
        
        # apply special effects to profiles
        # self._apply_special_things()
        
        if not self.io.full_image: # activate grain, halation, and glare only with full image
            self.negative.grain.active = False
            self.negative.halation.active = False
            # self.negative.glare.active = False
            # self.print_paper.glare.active = False
        
        # film exposure in camera and chemical development
        raw = self._expose_film(image, exposure_ev, pixel_size_um)
        if self.io.compute_film_raw: return raw

        log_raw = np.log10(np.fmax(raw, 0.0) + 1e-10)
        density_cmy = self._develop_film(log_raw, pixel_size_um)
        if self.debug.return_negative_density_cmy: return density_cmy
        
        # print exposure with enlarger
        if not self.io.compute_negative:
            log_raw = self._expose_print(density_cmy)
            density_cmy = self._develop_print(log_raw)
            if self.debug.return_print_density_cmy: return density_cmy
        
        # scan
        scan = self._scan(density_cmy)
        
        # rescale output
        scan = self._rescale_to_original(scan, preview_resize_factor)
        return scan

    ################################################################################
    
    @timeit('_auto_exposure')        
    def _auto_exposure(self, image):
        if self.camera.auto_exposure:
            input_color_space = self.io.input_color_space
            input_cctf = self.io.input_cctf_decoding
            method = self.camera.auto_exposure_method
            autoexposure_ev = measure_autoexposure_ev(image, input_color_space, input_cctf, method=method)
            exposure_ev = autoexposure_ev + self.camera.exposure_compensation_ev
        else:
            exposure_ev = self.camera.exposure_compensation_ev
        return exposure_ev
    
    @timeit('_crop_and_rescale')        
    def _crop_and_rescale(self, image):
        preview_resize_factor = self.io.preview_resize_factor
        upscale_factor = self.io.upscale_factor
        film_format_mm = self.camera.film_format_mm
        pixel_size_um = film_format_mm*1000 / np.max(image.shape)
        if self.io.crop:
            image = crop_image(image, center=self.io.crop_center, size=self.io.crop_size)
        if self.io.full_image:
            preview_resize_factor = 1.0
        if preview_resize_factor*upscale_factor != 1.0:
            image  = skimage.transform.rescale(image, preview_resize_factor*upscale_factor, channel_axis=2)
            pixel_size_um /= preview_resize_factor*upscale_factor
        return image, preview_resize_factor, pixel_size_um
    
    @timeit('_expose_film')
    def _expose_film(self, image, exposure_ev, pixel_size_um):
        raw = self._rgb_to_film_raw(image, exposure_ev,
                                    color_space=self.io.input_color_space,
                                    apply_cctf_decoding=self.io.input_cctf_decoding,
                                    use_lut=self.settings.use_camera_lut)
        raw = apply_gaussian_blur_um(raw, self.camera.lens_blur_um, pixel_size_um)
        raw = apply_halation_um(raw, self.negative.halation, pixel_size_um)
        return raw

    @timeit('_develop_film')
    def _develop_film(self, log_raw, pixel_size_um):
        film = Film(self.negative)
        density_cmy = film.develop(log_raw, pixel_size_um,
                                   use_fast_stats=self.settings.use_fast_stats)
        return density_cmy
    
    @timeit('_expose_print')
    def _expose_print(self, film_density_cmy):
        film_density_cmy_normalized = self._normalize_film_density(film_density_cmy) # 0-1 density for lut
        def spectral_calculation(density_cmy_n):
            density_cmy = self._denormalize_film_density(density_cmy_n)
            return self._film_density_cmy_to_print_log_raw(density_cmy)
        log_raw = self._spectral_lut_compute(film_density_cmy_normalized, spectral_calculation,
                                             use_lut=self.settings.use_enlarger_lut)
        return log_raw
    
    @timeit('_develop_print')
    def _develop_print(self, log_raw):
        density_cmy = develop_simple(self.print_paper, log_raw)
        return density_cmy
    
    @timeit('_scan')
    def _scan(self, density_cmy):
        rgb = self._density_cmy_to_rgb(density_cmy, use_lut=self.settings.use_scanner_lut)
        rgb = self._apply_blur_and_unsharp(rgb)
        rgb = self._apply_cctf_encoding_and_clip(rgb)
        return rgb 

    ################################################################################

    def _rescale_to_original(self, scan, preview_resize_factor):
        if preview_resize_factor != 1.0:
            scan = skimage.transform.rescale(scan, 1/preview_resize_factor, channel_axis=2)
        return scan
    
    def _spectral_lut_compute(self, data, spectral_calculation,
                              use_lut=False):
        steps = self.settings.lut_resolution
        if use_lut:
            data_out = compute_with_lut(data, spectral_calculation, steps=steps)
        else:                                   
            data_out = spectral_calculation(data)
        return data_out

    ################################################################################
    # Film calculations (maybe move them in emulsion)

    def _rgb_to_film_raw(self, rgb, exposure_ev,
                         color_space='sRGB', apply_cctf_decoding=False,
                         use_lut=False):
        sensitivity = 10**self.negative.data.log_sensitivity
        sensitivity = np.nan_to_num(sensitivity) # replace nans with zeros
        
        # applu band pass filter
        if self.camera.filter_uv[0]>0 or self.camera.filter_ir[0]>0:
            band_pass_filter = compute_band_pass_filter(self.camera.filter_uv,
                                                        self.camera.filter_ir)
            sensitivity *= band_pass_filter[:,None]

        method = self.settings.rgb_to_raw_method
        raw = np.zeros_like(rgb)
        if method=='mallett2019':
            raw = rgb_to_raw_mallett2019(rgb,
                                         sensitivity,
                                         color_space=color_space,
                                         apply_cctf_decoding=apply_cctf_decoding,
                                         reference_illuminant=self.negative.info.reference_illuminant)
        if method=='hanatos2025':
            raw = rgb_to_raw_hanatos2025(rgb,
                                         sensitivity,
                                         color_space=color_space,
                                         apply_cctf_decoding=apply_cctf_decoding,
                                         reference_illuminant=self.negative.info.reference_illuminant)
        
        # set exposure level
        raw *= 2**exposure_ev
        return raw

    def _normalize_film_density(self, denisty_cmy):
        density_max = np.nanmax(self.negative.data.density_curves, axis=0)
        density_min = self.negative.grain.density_min
        density_max += density_min
        density_cmy_normalized = (denisty_cmy + density_min) / density_max
        return density_cmy_normalized
    
    def _denormalize_film_density(self, density_cmy_normalized):
        density_max = np.nanmax(self.negative.data.density_curves, axis=0)
        density_min = self.negative.grain.density_min
        density_max += density_min
        density_cmy = density_cmy_normalized * density_max - density_min
        return density_cmy
    
    ################################################################################
    # Print calculations (maybe move them in emulsion)
    
    def _film_density_cmy_to_print_log_raw(self, density_cmy):
        sensitivity = 10**self.print_paper.data.log_sensitivity
        sensitivity = np.nan_to_num(sensitivity) # replace nans with zeros
        enlarger_light_source = standard_illuminant(self.enlarger.illuminant)
        raw = np.zeros_like(density_cmy)
        if not self.enlarger.just_preflash:
            density_spectral = compute_density_spectral(self.negative, density_cmy)
            print_illuminant = self._compute_print_illuminant(enlarger_light_source)
            light = density_to_light(density_spectral, print_illuminant)
            raw = contract('ijk, kl->ijl', light, sensitivity)
            raw *= self.enlarger.print_exposure # adjust print exposure
            raw_midgray_factor = self._compute_exposure_factor_midgray(sensitivity, print_illuminant)
            # print('raw midgray factor:', raw_midgray_factor)
            raw *= raw_midgray_factor # scale with negative midgray factor
        raw_preflash = self._compute_raw_preflash(enlarger_light_source, sensitivity)
        raw += raw_preflash # add preflash
        log_raw = np.log10(raw + 1e-10)
        return log_raw
    
    def _compute_print_illuminant(self, light_source):
        y_filter = self.enlarger.y_filter_neutral*ENLARGER_STEPS + self.enlarger.y_filter_shift
        m_filter = self.enlarger.m_filter_neutral*ENLARGER_STEPS + self.enlarger.m_filter_shift
        c_filter = self.enlarger.c_filter_neutral*ENLARGER_STEPS
        print_illuminant = color_enlarger(light_source, y_filter, m_filter, c_filter)
        return print_illuminant
    
    def _compute_preflash_illuminant(self, light_source):
        y_filter_preflash = self.enlarger.y_filter_neutral*ENLARGER_STEPS + self.enlarger.preflash_y_filter_shift
        m_filter_preflash = self.enlarger.m_filter_neutral*ENLARGER_STEPS + self.enlarger.preflash_m_filter_shift
        c_filter = self.enlarger.c_filter_neutral*ENLARGER_STEPS
        preflash_illuminant = color_enlarger(light_source, y_filter_preflash, m_filter_preflash, c_filter)
        return preflash_illuminant

    def _compute_raw_preflash(self, light_source, sensitivity):
        if self.enlarger.preflash_exposure > 0:
            preflash_illuminant = self._compute_preflash_illuminant(light_source)
            density_base = self.negative.data.dye_density[:, 3][None, None, :]
            light_preflash = density_to_light(density_base, preflash_illuminant)
            raw_preflash = contract('ijk, kl->ijl', light_preflash, sensitivity)
            raw_preflash *= self.enlarger.preflash_exposure
        else:
            raw_preflash = np.zeros((3))
        return raw_preflash
    
    def _compute_exposure_factor_midgray(self, sensitivity, print_illuminant):
        if self.enlarger.print_exposure_compensation:
            neg_exp_comp_ev = self.camera.exposure_compensation_ev
        else:
            neg_exp_comp_ev = 0.0
        rgb_midgray = np.array([[[0.184]*3]]) * 2**neg_exp_comp_ev
        raw_midgray = self._rgb_to_film_raw(rgb_midgray, exposure_ev=0.0, use_lut=False)
        log_raw_midgray = np.log10(raw_midgray + 1e-10)
        # film = Film(self.negative) # TODO: fix this using a function 
        density_cmy_midgray = develop_simple(self.negative, log_raw_midgray)
        density_spectral_midgray = compute_density_spectral(self.negative, density_cmy_midgray)
        light_midgray = density_to_light(density_spectral_midgray, print_illuminant)
        raw_midgray = contract('ijk, kl->ijl', light_midgray, sensitivity)
        factor = 1/raw_midgray[:,:,1]
        return factor
    
    def _normalize_print_density(self, denisty_cmy):
        density_max = np.nanmax(self.print_paper.data.density_curves, axis=0)
        density_cmy_normalized = denisty_cmy / density_max
        return density_cmy_normalized
    
    def _denormalize_print_density(self, density_cmy_normalized):
        density_max = np.nanmax(self.print_paper.data.density_curves, axis=0)
        density_cmy = density_cmy_normalized * density_max
        return density_cmy

    ################################################################################
    # Scanner calculations
    
    def _density_cmy_to_rgb(self, density_cmy, use_lut):
        if self.io.compute_negative:
            density_cmy_n = self._normalize_film_density(density_cmy)
            profile = self.negative
        else:
            density_cmy_n = self._normalize_print_density(density_cmy)
            profile = self.print_paper
        scan_illuminant = standard_illuminant(profile.info.viewing_illuminant)
        normalization = np.sum(scan_illuminant * STANDARD_OBSERVER_CMFS[:, 1], axis=0)
        
        # spectral calculation
        def spectral_calculation(density_cmy_n):
            if self.io.compute_negative:
                density_cmy = self._denormalize_film_density(density_cmy_n)
            else:
                density_cmy = self._denormalize_print_density(density_cmy_n)
            density_spectral = compute_density_spectral(profile, density_cmy)
            light = density_to_light(density_spectral, scan_illuminant)            
            xyz = contract('ijk,kl->ijl', light, STANDARD_OBSERVER_CMFS[:]) / normalization
            log_xyz = np.log10(xyz + 1e-10)
            return log_xyz
        log_xyz = self._spectral_lut_compute(density_cmy_n, spectral_calculation,
                                             use_lut=use_lut)
        xyz = 10**log_xyz
        
        illuminant_xyz = contract('k,kl->l', scan_illuminant, STANDARD_OBSERVER_CMFS[:]) / normalization
        xyz = add_glare(xyz, illuminant_xyz, profile)
        illuminant_xy = colour.XYZ_to_xy(illuminant_xyz)
        rgb = colour.XYZ_to_RGB(xyz,
                                colourspace=self.io.output_color_space, 
                                apply_cctf_encoding=False,
                                illuminant=illuminant_xy)
        return rgb
    
    def _apply_blur_and_unsharp(self, data):
        data = apply_gaussian_blur(data, self.scanner.lens_blur)
        unsharp_mask = self.scanner.unsharp_mask
        if unsharp_mask[0] > 0 and unsharp_mask[1] > 0:
            data = apply_unsharp_mask(data, sigma=unsharp_mask[0], amount=unsharp_mask[1])
        return data
    
    def _apply_cctf_encoding_and_clip(self, rgb):
        color_space = self.io.output_color_space
        if self.io.output_cctf_encoding:
            rgb = colour.RGB_to_RGB(rgb, color_space, color_space,
                    apply_cctf_decoding=False,
                    apply_cctf_encoding=True)
        rgb = np.clip(rgb, a_min=0, a_max=1)
        return rgb
        
def add_glare(xyz, illuminant_xyz, profile):
    if profile.glare.active and profile.glare.percent>0:
        glare_amount = compute_random_glare_amount(profile.glare.percent,
                                                profile.glare.roughness,
                                                profile.glare.blur,
                                                xyz.shape[:2])
        xyz += glare_amount[:,:,None] * illuminant_xyz[None,None,:]
    return xyz

def photo_process(image, params):
    photo = AgXPhoto(params)
    image_out = photo.process(image)
    if params.debug.print_timings:
        print(photo.timings)
        plot_timings(photo.timings)
    return image_out
    
if __name__ == '__main__':
    import matplotlib.pyplot as plt
    from agx_emulsion.utils.io import load_image_oiio
    from agx_emulsion.utils.numba_warmup import warmup
    warmup()
    # image = load_image_oiio('img/targets/cc_halation.png')
    # image = plt.imread('img/targets/it87_test_chart_2.jpg')
    # image = np.double(image[:,:,:3])/255
    image = load_image_oiio('img/test/portrait_leaves_32bit_linear_prophoto_rgb.tif')
    # image = [[[0.184,0.184,0.184]]]
    # image = [[[0,0,0], [0.184,0.184,0.184], [1,1,1]]]
    params = photo_params(print_paper='kodak_portra_endura_uc')
    params.io.input_cctf_decoding = True
    params.print_paper.glare.active = False
    params.debug.deactivate_stochastic_effects = False
    params.camera.exposure_compensation_ev = 0
    params.camera.auto_exposure = True
    params.io.preview_resize_factor = 0.3
    params.io.upscale_factor = 3.0
    params.io.full_image = False
    params.io.compute_negative = False
    params.negative.grain.agx_particle_area_um2 = 1
    params.enlarger.preflash_exposure = 0.0
    params.enlarger.print_exposure_compensation = True
    params.enlarger.print_exposure = 1.0
    params.negative.grain.active = False
    params.debug.return_negative_density_cmy = False
    params.debug.return_print_density_cmy = False
    
    params.settings.use_fast_stats = True
    params.settings.use_camera_lut = True
    params.settings.use_enlarger_lut = True
    params.settings.use_scanner_lut = True
    params.settings.lut_resolution = 32
    params.debug.print_timings = True
    image = photo_process(image, params)
    # plt.imshow(image[:,:,1])
    plt.imshow(image)
    plt.show()