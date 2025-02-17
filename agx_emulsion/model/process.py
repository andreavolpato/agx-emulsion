import numpy as np
import copy
from dotmap import DotMap

from agx_emulsion.config import ENLARGER_STEPS
from agx_emulsion.model.emulsion import Film, PrintPaper
from agx_emulsion.utils.autoexposure import measure_autoexposure_ev
from agx_emulsion.model.color_filters import color_enlarger
from agx_emulsion.utils.crop_resize import crop_image, resize_image
from agx_emulsion.model.illuminants import standard_illuminant
from agx_emulsion.utils.io import read_neutral_ymc_filter_values
from agx_emulsion.profiles.io import load_profile

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

    params.io.input_color_space = 'sRGB'
    params.io.input_cctf_decoding = True
    params.io.output_color_space = 'sRGB'
    params.io.output_cctf_encoding = True
    params.io.crop = False
    params.io.crop_center = (0.5,0.5)
    params.io.crop_size = (0.1, 1.0)
    params.io.preview_resize_factor = 1.0
    params.io.upscale_factor = 1.0
    params.io.full_image = False
    params.io.compute_negative = False
    
    params.debug.deactivate_spatial_effects = False
    params.debug.deactivate_grain = False
    params.debug.input_negative_density_cmy = False
    params.debug.return_negative_density_cmy = False
    params.debug.return_print_density_cmy = False
    
    return params

class AgXPhoto():
    def __init__(self, params):
        self._params = copy.deepcopy(params)
        self.negative = Film(params.negative)
        self.print_paper = PrintPaper(params.print_paper)
        self.camera = params.camera
        self.enlarger = params.enlarger
        self.scanner = params.scanner
        self.io = params.io
        self.debug = params.debug
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

        if self.debug.deactivate_grain:
            self.negative.grain.active = False

    def process(self, image):
        image = np.double(np.array(image)[:,:,0:3])
        
        # input
        exposure_ev = self._auto_exposure(image)
        image, preview_resize_factor, pixel_size_um = self._crop_and_rescale(image)
        
        # film exposure in camera
        log_raw = self._expose_film(image, exposure_ev)
        density_cmy = self._develop_film(log_raw, pixel_size_um)
        if self.debug.return_film_density_cmy: return density_cmy
        
        # print exposure with enlarger
        if not self.io.compute_negative:
            log_raw = self._expose_print(density_cmy)
            density_cmy = self._develop_print(log_raw)
            if self.debug.return_print_density_cmy: return density_cmy
        
        # scan
        scan = self._scan(density_cmy)
        scan = self._rescale_to_original(scan, preview_resize_factor)
        return scan

    def process_midscale_neutral(self):
        # used only to fit print filters
        density = self.negative.get_density_mid()
        density = self._expose_print_paper(density)
        scan = self._scan(density)
        return scan

    ################################################################################
            
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
            image  = resize_image(image, preview_resize_factor*upscale_factor)
            pixel_size_um /= preview_resize_factor*upscale_factor
        return image, preview_resize_factor, pixel_size_um
    
    def _expose_film(self, image, exposure_ev):
        # image >> linear_RGB 
        # - RGB >> linear_RGB
        # - _apply_camera_lens_blur(linear_RGB)
        
        # (next two steps could go through a LUT or matrix)
        # linear_RGB to raw
        # - linear_RGB >> spectral 
        # - spectral + sensitivities >> raw
        
        # raw processing
        # - add halation
        # raw >> log_raw
        
    
    def _expose_negative(self, image, exposure_ev, pixel_size_um):
        density_spectral = self.negative.expose(image,
                                exposure_ev=exposure_ev,
                                pixel_size_um=pixel_size_um,
                                color_space=self.io.input_color_space,
                                apply_cctf_decoding=self.io.input_cctf_decoding,
                                lens_blur_um=self.camera.lens_blur_um,
                                return_density_cmy=self.debug.return_negative_density_cmy)
        return density_spectral
    
    def _expose_print_paper(self, density_spectral):
        y_filter = self.enlarger.y_filter_neutral*ENLARGER_STEPS + self.enlarger.y_filter_shift
        m_filter = self.enlarger.m_filter_neutral*ENLARGER_STEPS + self.enlarger.m_filter_shift
        c_filter = self.enlarger.c_filter_neutral*ENLARGER_STEPS
        light_source = standard_illuminant(self.enlarger.illuminant)
        print_illuminant = color_enlarger(light_source, y_filter, m_filter, c_filter)
        y_filter_preflash = self.enlarger.y_filter_neutral*ENLARGER_STEPS + self.enlarger.preflash_y_filter_shift
        m_filter_preflash = self.enlarger.m_filter_neutral*ENLARGER_STEPS + self.enlarger.preflash_m_filter_shift
        illuminant_preflash = color_enlarger(light_source, y_filter_preflash, m_filter_preflash, c_filter)
        if self.enlarger.just_preflash:
            self.enlarger.print_exposure = 0.0
        if self.enlarger.print_exposure_compensation:
            print_exposure_compensation_ev = self.camera.exposure_compensation_ev
        else:
            print_exposure_compensation_ev = 0.0
                
        density_spectral = self.print_paper.print(density_spectral, print_illuminant, self.negative,
                               exposure=self.enlarger.print_exposure,
                               negative_exposure_compensation_ev=print_exposure_compensation_ev,
                               preflashing_exposure=self.enlarger.preflash_exposure,
                               preflashing_illuminant=illuminant_preflash,
                               lens_blur=self.enlarger.lens_blur)
        return density_spectral
    
    def _scan(self, density_spectral):
        if self.io.compute_negative:
            scan = self.negative.scan(density_spectral,
                                      standard_illuminant(self.negative.viewing_illuminant),
                                      color_space=self.io.output_color_space,
                                      apply_cctf_encoding=self.io.output_cctf_encoding,
                                      lens_blur=self.scanner.lens_blur,
                                      unsharp_mask=self.scanner.unsharp_mask)
        else:
            scan = self.print_paper.scan(density_spectral, 
                                         standard_illuminant(self.print_paper.viewing_illuminant),
                                         color_space=self.io.output_color_space,
                                         apply_cctf_encoding=self.io.output_cctf_encoding,
                                         lens_blur=self.scanner.lens_blur,
                                         unsharp_mask=self.scanner.unsharp_mask)
        return scan
    
    def _rescale_to_original(self, scan, preview_resize_factor):
        if preview_resize_factor != 1.0:
            scan = resize_image(scan, 1.0/preview_resize_factor)
        return scan

def photo_process(image, params):
    photo = AgXPhoto(params)
    return photo.process(image)
    
if __name__ == '__main__':
    import matplotlib.pyplot as plt
    from agx_emulsion.utils.io import read_png_16bit
    image = read_png_16bit('img/targets/cc_halation.png')
    params = photo_params()
    params.io.preview_resize_factor = 1.0
    image = photo_process(image, params)
    plt.imshow(image)
    
    system = AgXPhoto(params)
    print(system.process_midscale_neutral())
    
    plt.show()