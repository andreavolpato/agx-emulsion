import numpy as np
# import colour
import scipy.ndimage
# import gc
from opt_einsum import contract
# from agx_emulsion.config import STANDARD_OBSERVER_CMFS
# from agx_emulsion.model.illuminants import standard_illuminant
from agx_emulsion.model.density_curves import interpolate_exposure_to_density
# from agx_emulsion.utils.conversions import density_to_light
# from agx_emulsion.model.diffusion import apply_unsharp_mask, apply_halation_um
from agx_emulsion.model.couplers import compute_exposure_correction_dir_couplers, compute_dir_couplers_matrix, compute_density_curves_before_dir_couplers
from agx_emulsion.model.grain import apply_grain_to_density, apply_grain_to_density_layers
# from agx_emulsion.model.parametric import parametric_density_curves_model
from agx_emulsion.utils.fast_stats import fast_lognormal_from_mean_std
from agx_emulsion.utils.fast_interp import fast_interp
# from agx_emulsion.utils.fast_gaussian_filter import fast_gaussian_filter

################################################################################
# AgXEmusion main class

def remove_viewing_glare_comp(le, dc, factor=0.2, density=1.0, transition=0.3):
    """
    Removes viewing glare compensation from the density curves of print paper.
    Parameters:
    le (numpy.ndarray): The log exposure values.
    dc (numpy.ndarray): density curves of the print paper. Shape (n,3).
    factor (float, optional): The factor by which to reduce the light exposure values of the shadows. (brighter shadows). Default is 0.1.
    density (float, optional): The density value of the transition point. Default is 1.2.
    transition (float, optional): The transition density range used for Gaussian filtering. Default is 0.3.
    Returns:
    numpy.ndarray: density curves with viewing glare compensation removed.
    """
    def _measure_slope(le, density_curve, le_center, range_ev=1):
        le_delta = np.log10(2**range_ev)/2
        le_0 = le_center - le_delta
        le_1 = le_center + le_delta
        density_0 = np.interp(le_0, le, density_curve)
        density_1 = np.interp(le_1, le, density_curve)
        slope = (density_1 - density_0)/(le_1 - le_0)
        return slope    
    
    dc_mean = np.mean(dc, axis=1)
    le_center = np.interp(density, dc_mean, le)
    slope = _measure_slope(le, dc_mean, le_center)
    le_step = np.mean(np.diff(le))
    dc_out = np.zeros_like(dc)
    for i in np.arange(3):
        le_nl = np.copy(le)
        le_nl[le>le_center] -= (le[le>le_center]-le_center)*factor
        le_transition = transition/slope
        le_nl = scipy.ndimage.gaussian_filter(le_nl, le_transition/le_step)
        dc_out[:,i] = np.interp(le_nl, le, dc[:,i])
    return dc_out

def lognorm_from_mean_std(M, S):
    """
    Returns a frozen lognormal distribution object (scipy.stats.rv_frozen)
    whose mean is M and std dev is S in linear space.
    """
    # 1. Compute sigma^2 in log-space
    sigma_sq = np.log(1.0 + (S**2) / (M**2))
    sigma = np.sqrt(sigma_sq)
    # 2. Compute mu in log-space
    mu = np.log(M) - 0.5 * sigma_sq
    # 3. In scipy.lognorm, 's' = sigma (the shape), and 'scale' = exp(mu)
    return scipy.stats.lognorm(s=sigma, scale=np.exp(mu))

def compute_random_glare_amount(amount, roughness, blur, shape):
    random_glare = fast_lognormal_from_mean_std(amount*np.ones(shape),
                                                roughness*amount*np.ones(shape))
    random_glare = scipy.ndimage.gaussian_filter(random_glare, blur)
    # random_glare = fast_gaussian_filter(random_glare, blur)
    random_glare /= 100
    return random_glare

def compute_density_spectral(profile, density_cmy):
    density_spectral = contract('ijk, lk->ijl', density_cmy, profile.data.dye_density[:, 0:3])
    density_spectral += profile.data.dye_density[:, 3] * profile.data.tune.dye_density_min_factor
    return density_spectral

def develop_simple(profile, log_raw):
    density_curves = profile.data.density_curves
    log_exposure = profile.data.log_exposure
    gamma_factor = profile.data.tune.gamma_factor
    density_cmy = interpolate_exposure_to_density(log_raw, density_curves, log_exposure, gamma_factor)
    return density_cmy

class AgXEmulsion():
    def __init__(self, profile):
        self.sensitivity = 10**np.array(profile.data.log_sensitivity)
        self.dye_density = np.array(profile.data.dye_density)
        self.density_curves = np.array(profile.data.density_curves)
        self.density_curves_layers = np.array(profile.data.density_curves_layers)
        self.log_exposure = np.array(profile.data.log_exposure)
        self.wavelengths = np.array(profile.data.wavelengths)
        
        self.parametric = profile.parametric
        self.type = profile.info.type
        self.stock = profile.info.stock
        self.reference_illuminant = profile.info.reference_illuminant
        self.viewing_illuminant = profile.info.viewing_illuminant
        self.gamma_factor = profile.data.tune.gamma_factor
        self.dye_density_min_factor = profile.data.tune.dye_density_min_factor
        
        self.density_curves -= np.nanmin(self.density_curves, axis=0)
        self.sensitivity = np.nan_to_num(self.sensitivity) # replace nans with zeros
        self.midgray_value = 0.184 # in linear light value, no cctf applied
        self.midgray_rgb = np.array([[[self.midgray_value]*3]])
    
    ################################################################################
    # Generic methods

    def _interpolate_density_with_curves(self, log_raw, density_curves=None):
        if density_curves is None: 
            density_curves = self.density_curves
        density_cmy = interpolate_exposure_to_density(log_raw, density_curves, self.log_exposure, self.gamma_factor)
        return density_cmy

    def _compute_density_spectral(self, density_cmy):
        density_spectral = contract('ijk, lk->ijl', density_cmy, self.dye_density[:, 0:3])
        density_spectral += self.dye_density[:, 3] * self.dye_density_min_factor
        return density_spectral
    
    # def _gaussian_blur(self, data, sigma):
    #     if sigma > 0:
    #         return scipy.ndimage.gaussian_filter(data, (sigma, sigma, 0))
    #     else:
    #         return data
    
    ################################################################################
    
    # def scan(self,
    #          density_spectral,
    #          illuminant,
    #          color_space='sRGB',
    #          apply_cctf_encoding=True,
    #          lens_blur=0.0,
    #          unsharp_mask=[0.0,0.8]):
    #     light = self._calculate_light_transmitted(density_spectral, illuminant)
    #     rgb   = self._add_glare_and_convert_light_to_RGB(light, illuminant, color_space)
    #     rgb   = self._apply_blur_and_unsharp(rgb, lens_blur, unsharp_mask)
    #     rgb   = self._apply_cctf_encoding_and_clip(rgb, color_space, apply_cctf_encoding)
    #     return rgb
        
    # def _calculate_light_transmitted(self, density_spectral, illuminant):
    #     return density_to_light(density_spectral, illuminant)
    
    # def _add_glare_and_convert_light_to_RGB(self, light_transmitted, illuminant, color_space):
    #     normalization = np.sum(illuminant * STANDARD_OBSERVER_CMFS[:, 1], axis=0)
    #     xyz = contract('ijk,kl->ijl', light_transmitted, STANDARD_OBSERVER_CMFS[:]) / normalization
    #     illuminant_xyz = contract('k,kl->l', illuminant, STANDARD_OBSERVER_CMFS[:]) / normalization
    #     if self.type=='paper' and self.glare.active and self.glare.percent>0:
    #         glare_amount = compute_random_glare_amount(self.glare.percent, self.glare.roughness, self.glare.blur, light_transmitted.shape[:2])
    #         xyz += glare_amount[:,:,None] * illuminant_xyz[None,None,:]
    #     illuminant_xy = colour.XYZ_to_xy(illuminant_xyz)
    #     rgb = colour.XYZ_to_RGB(xyz, colourspace=color_space, apply_cctf_encoding=False, illuminant=illuminant_xy)
    #     return rgb

    # def _apply_blur_and_unsharp(self, data, sigma_blur, unsharp_mask):
    #     data = self._gaussian_blur(data, sigma_blur)
    #     if unsharp_mask[0] > 0 and unsharp_mask[1] > 0:
    #         data = apply_unsharp_mask(data, sigma=unsharp_mask[0], amount=unsharp_mask[1])
    #     return data

    # def _apply_cctf_encoding_and_clip(self, rgb, color_space, apply_cctf_encoding):
    #     if apply_cctf_encoding:
    #         # rgb = colour.cctf_encoding(rgb, function=color_space)
    #         rgb = colour.RGB_to_RGB(rgb, color_space, color_space,
    #                 apply_cctf_decoding=False,
    #                 apply_cctf_encoding=True)
    #     rgb = np.clip(rgb, a_min=0, a_max=1)
    #     return rgb

################################################################################

class Film(AgXEmulsion):
    def __init__(self, profile):
        super().__init__(profile)
        self.grain = profile.grain
        self.halation = profile.halation
        self.dir_couplers = profile.dir_couplers
        self.density_midscale_neutral = profile.info.density_midscale_neutral

    def develop(self, log_raw, pixel_size_um,
                bypass_grain=False,
                use_fast_stats=False,
                ):

        # self.exposure_ev = exposure_ev
        # self.replace_data_with_parametric_models() #DEL
        # raw              = self._convert_rgb_to_raw_and_expose(rgb, color_space, apply_cctf_decoding, exposure_ev)
        # raw              = self._gaussian_blur(raw, lens_blur_um/pixel_size_um)
        # raw              = self._apply_halation(raw, pixel_size_um)
        # log_raw          = np.log10(raw + 1e-10)
        density_cmy      = self._interpolate_density_with_curves(log_raw)
        density_cmy      = self._apply_density_correction_dir_couplers(density_cmy, log_raw, pixel_size_um)
        density_cmy      = self._apply_grain(density_cmy, pixel_size_um, bypass_grain, use_fast_stats)
        # density_spectral = self._compute_density_spectral(density_cmy) #DEL
        return density_cmy
        
        # if return_density_cmy: return density_cmy # only used for grain tuning with a virtual densitometer
        # else:                  return density_spectral #DEL

    # def replace_data_with_parametric_models(self): #DEL
    #     if self.parametric.density_curves.active:
    #         gamma = self.parametric.density_curves.gamma
    #         log_exposure_0 = self.parametric.density_curves.log_exposure_0
    #         density_max = self.parametric.density_curves.density_max
    #         toe_size = self.parametric.density_curves.toe_size
    #         shoulder_size = self.parametric.density_curves.shoulder_size
    #         self.density_curves = parametric_density_curves_model(self.log_exposure, gamma, log_exposure_0, density_max, toe_size, shoulder_size)

    # def _convert_rgb_to_raw_and_expose(self, rgb, color_space, apply_cctf_decoding, exposure_ev): #DEL
    #     reference_illuminant = standard_illuminant(self.reference_illuminant)
    #     raw = rgb_to_raw_mallett2019(rgb, reference_illuminant, self.sensitivity,
    #                                  color_space=color_space,
    #                                  apply_cctf_decoding=apply_cctf_decoding)
    #     raw_midgray = rgb_to_raw_mallett2019(self.midgray_rgb, reference_illuminant, self.sensitivity,
    #                                          color_space='sRGB',
    #                                          apply_cctf_decoding=False)
    #     raw *= 2**exposure_ev / raw_midgray[:,:,1]
    #     return raw

    # def _apply_halation(self, raw, pixel_size_um): #DEL
    #     if self.halation.active:
    #         halation_size_pixels = np.array(self.halation.size_um)/pixel_size_um
    #         scattering_size_pixels = np.array(self.halation.scattering_size_um)/pixel_size_um
    #         raw = apply_halation(raw, 
    #                             np.array(halation_size_pixels),
    #                             np.array(self.halation.strength),
    #                             np.array(scattering_size_pixels),
    #                             np.array(self.halation.scattering_strength))
    #     return raw

    def _apply_density_correction_dir_couplers(self, density_cmy, log_raw, pixel_size_um):
        if self.dir_couplers.active:
            # compute inhibitors matrix with super a simplified diffusion model
            dir_couplers_amount_rgb = self.dir_couplers.amount * np.array(self.dir_couplers.ratio_rgb)
            M = compute_dir_couplers_matrix(dir_couplers_amount_rgb, self.dir_couplers.diffusion_interlayer)
            # compute density curves before dir couplers
            density_curves_0 = compute_density_curves_before_dir_couplers(self.density_curves, self.log_exposure, M, self.dir_couplers.high_exposure_shift)
            # compute exposure correction
            density_max = np.nanmax(self.density_curves, axis=0)
            diffusion_size_um = self.dir_couplers.diffusion_size_um
            diffusion_size_pixel = diffusion_size_um/pixel_size_um
            log_raw_0 = compute_exposure_correction_dir_couplers(log_raw, density_cmy, density_max, M, 
                                                                 diffusion_size_pixel, self.dir_couplers.high_exposure_shift)
            # interpolated with corrected curves
            density_cmy = interpolate_exposure_to_density(log_raw_0, density_curves_0, self.log_exposure, self.gamma_factor)
        return density_cmy

    def _apply_grain(self, density_cmy, pixel_size_um, bypass_grain, use_fast_stats):
        if self.grain.active and not bypass_grain:
            if not self.grain.sublayers_active:
                density_max = np.nanmax(self.density_curves, axis=0)
                density_cmy = apply_grain_to_density(density_cmy,
                                                    pixel_size_um=pixel_size_um,
                                                    agx_particle_area_um2=self.grain.agx_particle_area_um2,
                                                    agx_particle_scale=self.grain.agx_particle_scale,
                                                    density_min=self.grain.density_min,
                                                    density_max_curves=density_max,
                                                    grain_uniformity=self.grain.uniformity,
                                                    grain_blur=self.grain.blur,
                                                    n_sub_layers=self.grain.n_sub_layers)
            else:
                density_cmy_layers = interp_density_cmy_layers(density_cmy, self.density_curves, self.density_curves_layers)
                density_max_layers = np.nanmax(self.density_curves_layers, axis=0)
                density_cmy = apply_grain_to_density_layers(density_cmy_layers,
                                                            density_max_layers=density_max_layers,
                                                            pixel_size_um=pixel_size_um,
                                                            agx_particle_area_um2=self.grain.agx_particle_area_um2,
                                                            agx_particle_scale=self.grain.agx_particle_scale,
                                                            agx_particle_scale_layers=self.grain.agx_particle_scale_layers,
                                                            density_min=self.grain.density_min,
                                                            grain_uniformity=self.grain.uniformity,
                                                            grain_blur=self.grain.blur,
                                                            grain_blur_dye_clouds_um=self.grain.blur_dye_clouds_um,
                                                            grain_micro_structure=self.grain.micro_structure,
                                                            use_fast_stats=use_fast_stats)
        return density_cmy

    def get_density_mid(self):
        # assumes that dye density cmy are already scaled to fit the mid diffuse density
        d_mid = self.density_midscale_neutral
        density_spectral = np.sum(self.dye_density[:, :3] * d_mid, axis=1) + self.dye_density[:, 3]
        return density_spectral[None,None,:]


def interp_density_cmy_layers(density_cmy, density_curves, density_curves_layers):
    density_cmy_layers = np.zeros((density_cmy.shape[0], density_cmy.shape[1], 3, 3)) # x,y,layer,rgb
    # for ch in np.arange(3):
    #     for lr in np.arange(3):
    #         density_cmy_layers[:,:,lr,ch] = np.interp(density_cmy[:,:,ch],
    #                                                   density_curves[:,ch], density_curves_layers[:,lr,ch])
    for ch in np.arange(3):
            density_cmy_layers[:,:,:,ch] = fast_interp(np.repeat(density_cmy[:,:,ch,np.newaxis], 3, -1),
                                                     density_curves[:,ch], density_curves_layers[:,:,ch])
    return density_cmy_layers
    
################################################################################

# class PrintPaper(AgXEmulsion):
#     def __init__(self, profile):
#         super().__init__(profile)
#         self.glare = profile.glare
        
#     def print(self, negative_density_spectral, illuminant, negative,
#               exposure=1, negative_exposure_compensation_ev=0.0,
#               preflashing_illuminant=None, preflashing_exposure=0.0,
#               lens_blur=0.55):
#         if preflashing_illuminant is None:
#             preflashing_illuminant = illuminant
#         density_midgray      = self._expose_midgray(negative, negative_exposure_compensation_ev)
#         cmy                  = self._compute_cmy_layer_exposures(negative_density_spectral, illuminant, exposure)
#         del negative_density_spectral
#         gc.collect()
#         cmy                  = self._apply_preflashing(cmy, negative, preflashing_illuminant, preflashing_exposure)
#         cmy                  = self._scale_cmy_exposure_with_midgray(cmy, density_midgray, illuminant)
#         cmy                  = self._gaussian_blur(cmy, lens_blur) # of printing projection lens
#         log_cmy              = np.log10(cmy + 1e-10)
#         density_curves       = self._apply_viewing_glare_compensation_removal()
#         density_cmy          = self._interpolate_density_with_curves(log_cmy, density_curves)
#         density_spectral     = self._compute_density_spectral(density_cmy)

#         return density_spectral

#     def _expose_midgray(self, emulsion, negative_exposure_compensation_ev):
#         return emulsion.expose(self.midgray_rgb * 2**negative_exposure_compensation_ev,
#                                color_space='sRGB',
#                                apply_cctf_decoding=False,
#                                exposure_ev=0.0,
#                                compute_reference_exposure=True)

#     def _compute_cmy_layer_exposures(self, negative_density_spectral, illuminant, exposure):
#         light = density_to_light(negative_density_spectral, illuminant)
#         cmy = contract('ijk, kl->ijl', light, self.sensitivity)
#         return cmy * exposure

#     def _apply_preflashing(self, cmy, negative, preflashing_illuminant, preflashing_exposure):
#         if preflashing_exposure > 0:
#             density_base = negative.dye_density[:, 3][None, None, :]
#             light_preflashing = density_to_light(density_base, preflashing_illuminant)
#             cmy_preflashing = contract('ijk, kl->ijl', light_preflashing, self.sensitivity)
#             cmy += cmy_preflashing * preflashing_exposure
#         return cmy

#     def _scale_cmy_exposure_with_midgray(self, cmy, density_midgray, illuminant):
#         light_midgray = density_to_light(density_midgray, illuminant)
#         cmy_midgray = contract('ijk, kl->ijl', light_midgray, self.sensitivity)
#         cmy /= cmy_midgray[:,:,1]
#         return cmy
    
#     def _apply_viewing_glare_compensation_removal(self):
#         factor = self.glare.compensation_removal_factor
#         transition_density = self.glare.compensation_removal_density
#         transition_density_range = self.glare.compensation_removal_transition
#         if factor>0:
#             density_curves = remove_viewing_glare_comp(self.log_exposure, self.density_curves,
#                                                        factor=factor,
#                                                        density=transition_density,
#                                                        transition=transition_density_range)
#         else: density_curves = self.density_curves
#         return density_curves
    
#     # TODO: move color enlarger into print method
    
################################################################################
# Various
################################################################################

# Some todos
# TODO: add print dye shift. shift in nanometers of the dye absorption peaks
#       probably the best way to do this is by modeling the dye density absorption curves
# TODO: investigate on the behaviour of density curves when changing development conditions
#       density_curves should probably be modellable, like also sensityvity and dye_density
# TODO: make a gray card border to check white balance

if __name__=='__main__':
    from agx_emulsion.tests.test_main_simulation import test_main_simulation
    test_main_simulation()