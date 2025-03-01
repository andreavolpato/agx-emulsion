# import numpy as np
# import colour
# from agx_emulsion.model.diffusion import apply_gaussian_blur, apply_unsharp_mask

# def scan(self,
#             density_spectral,
#             illuminant,
#             color_space='sRGB',
#             apply_cctf_encoding=True,
#             lens_blur=0.0,
#             unsharp_mask=[0.0,0.8]):
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
#     data = apply_gaussian_blur(data, sigma_blur)
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