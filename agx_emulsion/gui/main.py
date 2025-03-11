import numpy as np
import napari
from enum import Enum
from napari.layers import Image
from napari.types import ImageData
from napari.settings import get_settings
from magicgui import magicgui
from pathlib import Path
# import matplotlib.pyplot as plt

from agx_emulsion.config import ENLARGER_STEPS
from agx_emulsion.utils.io import load_image_oiio
from agx_emulsion.model.process import  photo_params, photo_process
from agx_emulsion.model.stocks import FilmStocks, PrintPapers, Illuminants
# from agx_emulsion.model.parametric import parametric_density_curves_model
# from agx_emulsion.profiles.io import load_profile
from agx_emulsion.profiles.factory import swap_channels
from agx_emulsion.utils.numba_warmup import warmup

# precompile numba functions
warmup()

# create a viewer and add a couple image layers
viewer = napari.Viewer()
viewer.window._qt_viewer.dockLayerControls.setVisible(False)
viewer.window._qt_viewer.dockLayerList.setVisible(False)
layer_list = viewer.window.qt_viewer.dockLayerList
settings = get_settings()
settings.appearance.theme = 'light'

# portrait = load_image_oiio('img/test/portrait_leaves_32bit_linear_prophoto_rgb.tif')
# viewer.add_image(portrait,
#                  name="portrait")

class RGBColorSpaces(Enum):
    sRGB = 'sRGB'
    DCI_P3 = 'DCI-P3'
    DisplayP3 = 'Display P3'
    AdobeRGB = 'Adobe RGB (1998)'
    ITU_R_BT2020 = 'ITU-R BT.2020'
    ProPhotoRGB = 'ProPhoto RGB'
    ACES2065_1 = 'ACES2065-1'

class RGBtoRAWMethod(Enum):
    hanatos2025 = 'hanatos2025'
    mallett2019 = 'mallett2019'

class AutoExposureMethods(Enum):
    median = 'median'
    center_weighted = 'center_weighted'

@magicgui(layout="vertical", call_button='None')
def grain(active=True,
          sublayers_active=True,
          particle_area_um2=0.2,
          particle_scale=(0.8,1.0,2),
          particle_scale_layers=(2.5,1.0,0.5),
          density_min=(0.07, 0.08, 0.12),
          uniformity=(0.97,0.97,0.99),
          blur=0.65,
          blur_dye_clouds_um=1.0,
          micro_structure=(0.1, 30),
          ):
    return

@magicgui(layout="vertical", call_button='None')
def input_image(preview_resize_factor=0.3,
                upscale_factor=1.0,
                crop=False,
                crop_center=(0.50,0.50),
                crop_size=(0.1,0.1),
                input_color_space=RGBColorSpaces.ProPhotoRGB,
                apply_cctf_decoding=False,
                spectral_upsampling_method=RGBtoRAWMethod.hanatos2025,
                filter_uv=(1,410,8),
                filter_ir=(1,675,15),
                ):
    return

@magicgui(layout="vertical", call_button='None')
def preflashing(exposure=0.0,
                y_filter_shift=0,
                m_filter_shift=0,
                just_preflash=False):
    return

@magicgui(layout="vertical", call_button='None')
def halation(active=True,
             scattering_strength=(1.0,2.0,4.0),
             scattering_size_um=(30,20,15),
             halation_strength=(3.0,0.30,0.1),
             halation_size_um=(200,200,200)):
    return

@magicgui(layout="vertical", call_button='None')
def couplers(active=True,
             dir_couplers_amount=1.0,
             dir_couplers_ratio=(1.0,1.0,1.0),
             dir_couplers_diffusion_um=10,
             diffusion_interlayer=2.0,
             high_exposure_shift=0.0):
    return

@magicgui(layout="vertical", call_button='None')
def glare(active=True,
          percent=0.10,
          roughness=0.4,
          blur=0.5,
          compensation_removal_factor=0.0,
          compensation_removal_density=1.2,
          compensation_removal_transition=0.3):
    return

# @magicgui(layout="vertical", call_button='plot curves')
# def curves(use_parametric_curves=False,
#            gamma=(0.7,0.7,0.7),
#            log_exposure_0=(-1.4,-1.4,-1.52),
#            density_max=(2.75,2.75,2.84),
#            toe_size=(0.3,0.3,0.3),
#            shoulder_size=(0.85,0.85,0.85),):
#     profile = load_profile(simulation.film_stock.value.value)
#     print(simulation.film_stock.value.value)
#     log_exposure = profile.data.log_exposure
#     density_curves = parametric_density_curves_model(log_exposure,
#                                 gamma,
#                                 log_exposure_0,
#                                 density_max,
#                                 toe_size,
#                                 shoulder_size)
#     plt.figure()
#     colors = ['tab:red', 'tab:green', 'tab:blue']
#     labels = ['R', 'G', 'B']
#     gamma_factor = simulation.film_gamma_factor.value
#     for i in range(3):
#         plt.plot(log_exposure, density_curves[:,i], color=colors[i], label=labels[i])
#         plt.plot(log_exposure/gamma_factor[i], profile.data.density_curves, color=colors[i], linestyle='--', label=None)
#     plt.xlabel('log(Exposure)')
#     plt.ylabel('Density')
#     plt.legend()
#     plt.title(profile.info.stock)
#     plt.show()
#     return

# @magicgui(layout="vertical", call_button='fit negative density curves')
# def fit_density_curves():
#     return


@magicgui(filename={"mode": "r"}, call_button='load image (e.g. png/exr)')
def filepicker(filename=Path("./")) -> ImageData:
    img_array = load_image_oiio(str(filename))
    img_array = img_array[...,:3]
    return img_array

@magicgui(layout="vertical", call_button='None')
def special(film_channel_swap=(0,1,2),
            film_gamma_factor=1.0,
            print_channel_swap=(0,1,2),
            print_gamma_factor=1.0,
            print_density_min_factor=0.4,
            ):
    return

import json

def export_parameters(filepath, params):
    dot_params = DotMap(params)
    with open(filepath, 'w') as f:
        json.dump(dot_params.toDict(), f, indent=4)

def load_parameters(filepath):
    with open(filepath, 'r') as f:
        dot_params = DotMap(json.load(f))
    return dot_params.toDict()

# for details on why the `-> ImageData` return annotation works:
# https://napari.org/guides/magicgui.html#return-annotations
@magicgui(layout="vertical")
def simulation(input_layer:Image,
               film_stock=FilmStocks.kodak_gold_200,
               film_format_mm=35.0,
               camera_lens_blur_um=0.0,
               exposure_compensation_ev=0.0,
               auto_exposure=True,
               auto_exposure_method=AutoExposureMethods.center_weighted,
               # print parameters
               print_paper=PrintPapers.kodak_portra_endura,
               print_illuminant=Illuminants.lamp,
               print_exposure=1.0,
               print_exposure_compensation=True,
               print_y_filter_shift=0,
               print_m_filter_shift=0,
            #    print_lens_blur=0.0,
               # scanner
               scan_lens_blur=0.00,
               scan_unsharp_mask=(0.7,0.7),
               output_color_space=RGBColorSpaces.sRGB,
               output_cctf_encoding=True,
            #    compute_film_raw=False,
               compute_negative=False,
               compute_full_image=False,
               )->ImageData:    
    params = photo_params(film_stock.value, print_paper.value)
    
    if special.film_channel_swap.value != (0,1,2):
        params.negative = swap_channels(params.negative, special.film_channel_swap.value)
    if special.print_channel_swap.value != (0,1,2):
        params.print_paper = swap_channels(params.print_paper, special.print_channel_swap.value)
    
    params.negative.data.tune.gamma_factor = special.film_gamma_factor.value
    params.print_paper.data.tune.gamma_factor = special.print_gamma_factor.value
    params.print_paper.data.tune.dye_density_min_factor = special.print_density_min_factor.value
    params.print_paper.glare.active = glare.active.value
    params.print_paper.glare.percent = glare.percent.value
    params.print_paper.glare.roughness = glare.roughness.value
    params.print_paper.glare.blur = glare.blur.value
    params.print_paper.glare.compensation_removal_factor = glare.compensation_removal_factor.value
    params.print_paper.glare.compensation_removal_density = glare.compensation_removal_density.value
    params.print_paper.glare.compensation_removal_transition = glare.compensation_removal_transition.value

    params.camera.lens_blur_um = camera_lens_blur_um
    params.camera.exposure_compensation_ev = exposure_compensation_ev
    params.camera.auto_exposure = auto_exposure
    params.camera.auto_exposure_method = auto_exposure_method.value
    params.camera.film_format_mm = film_format_mm
    params.camera.filter_uv = input_image.filter_uv.value
    params.camera.filter_ir = input_image.filter_ir.value
    
    params.io.preview_resize_factor = input_image.preview_resize_factor.value
    params.io.upscale_factor = input_image.upscale_factor.value
    params.io.crop = input_image.crop.value
    params.io.crop_center = input_image.crop_center.value
    params.io.crop_size = input_image.crop_size.value
    params.io.input_color_space = input_image.input_color_space.value.value
    params.io.input_cctf_decoding = input_image.apply_cctf_decoding.value
    params.io.output_color_space = output_color_space.value
    params.io.output_cctf_encoding = output_cctf_encoding
    params.io.full_image = compute_full_image
    params.io.compute_negative = compute_negative
    # params.io.compute_film_raw = compute_film_raw
    
    # assign parameters to the film stock and paper
    params.negative.halation.active = halation.active.value
    params.negative.halation.strength = np.array(halation.halation_strength.value)/100
    params.negative.halation.size_um = np.array(halation.halation_size_um.value)
    params.negative.halation.scattering_strength = np.array(halation.scattering_strength.value)/100
    params.negative.halation.scattering_size_um = np.array(halation.scattering_size_um.value)
    
    params.negative.grain.active = grain.active.value
    params.negative.grain.sublayers_active = grain.sublayers_active.value
    params.negative.grain.agx_particle_area_um2 = grain.particle_area_um2.value
    params.negative.grain.agx_particle_scale = grain.particle_scale.value
    params.negative.grain.agx_particle_scale_layers = grain.particle_scale_layers.value
    params.negative.grain.density_min = grain.density_min.value
    params.negative.grain.uniformity = grain.uniformity.value
    params.negative.grain.blur = grain.blur.value
    params.negative.grain.blur_dye_clouds_um = grain.blur_dye_clouds_um.value
    params.negative.grain.micro_structure = grain.micro_structure.value
    
    params.negative.dir_couplers.active = couplers.active.value
    params.negative.dir_couplers.amount = couplers.dir_couplers_amount.value 
    params.negative.dir_couplers.ratio_rgb = couplers.dir_couplers_ratio.value
    params.negative.dir_couplers.diffusion_size_um = couplers.dir_couplers_diffusion_um.value
    params.negative.dir_couplers.diffusion_interlayer = couplers.diffusion_interlayer.value
    params.negative.dir_couplers.high_exposure_shift = couplers.high_exposure_shift.value
        
    # # parametric curves
    # params.negative.parametric.density_curves.active = curves.use_parametric_curves.value
    # params.negative.parametric.density_curves.gamma = curves.gamma.value
    # params.negative.parametric.density_curves.log_exposure_0 = curves.log_exposure_0.value
    # params.negative.parametric.density_curves.density_max = curves.density_max.value
    # params.negative.parametric.density_curves.toe_size = curves.toe_size.value
    # params.negative.parametric.density_curves.shoulder_size = curves.shoulder_size.value

    params.enlarger.illuminant = print_illuminant.value
    params.enlarger.print_exposure = print_exposure
    params.enlarger.print_exposure_compensation = print_exposure_compensation
    params.enlarger.y_filter_shift = print_y_filter_shift
    params.enlarger.m_filter_shift = print_m_filter_shift
    # params.enlarger.print_lens_blur = print_lens_blur
    params.enlarger.preflash_exposure = preflashing.exposure.value
    params.enlarger.preflash_y_filter_shift = preflashing.y_filter_shift.value
    params.enlarger.preflash_m_filter_shift = preflashing.m_filter_shift.value
    params.enlarger.just_preflash = preflashing.just_preflash.value
    
    params.scanner.lens_blur = scan_lens_blur
    params.scanner.unsharp_mask = scan_unsharp_mask
    
    params.settings.rgb_to_raw_method = input_image.spectral_upsampling_method.value.value
    params.settings.use_camera_lut = False
    params.settings.use_enlarger_lut = True
    params.settings.use_scanner_lut = True
    params.settings.lut_resolution = 32
    params.settings.use_fast_stats = True

    image = np.double(input_layer.data[:,:,:3])
    scan = photo_process(image, params)
    # if params.io.compute_film_raw:
    #     scan = np.vstack((scan[:, :, 0], scan[:, :, 1], scan[:, :, 2]))
    scan = np.uint8(scan*255)
    return scan

# add our new magicgui widget to the viewer
simulation.exposure_compensation_ev.min = -100
simulation.exposure_compensation_ev.max = 100
simulation.exposure_compensation_ev.step = 0.5
simulation.print_exposure.step = 0.05
simulation.print_y_filter_shift.min = -ENLARGER_STEPS
simulation.print_y_filter_shift.max = ENLARGER_STEPS
simulation.print_m_filter_shift.min = -ENLARGER_STEPS
simulation.print_m_filter_shift.max = ENLARGER_STEPS
# simulation.print_lens_blur.step = 0.05
simulation.scan_lens_blur.step = 0.05

# tooltips to help users understand what the widgets do
simulation.film_stock.tooltip = 'Film stock to simulate'
simulation.exposure_compensation_ev.tooltip = 'Exposure compensation value in ev of the negative'
simulation.auto_exposure.tooltip = 'Automatically adjust exposure based on the image content'
simulation.film_format_mm.tooltip = 'Long edge of the film format in millimeters, e.g. 35mm or 60mm'
simulation.camera_lens_blur_um.tooltip = 'Sigma of gaussian filter in um for the camera lens blur. About 5 um for typical lenses, down to 2-4 um for high quality lenses, used for sharp input simulations without lens blur.'
simulation.print_paper.tooltip = 'Print paper to simulate'
simulation.print_illuminant.tooltip = 'Print illuminant to simulate'
simulation.print_exposure.tooltip = 'Exposure value for the print (proportional to seconds of exposure, not ev)'
simulation.print_exposure_compensation.tooltip = 'Apply exposure compensation from negative exposure compensation ev, allow for changing of the negative exposure compensation while keeping constant print time.'
simulation.print_y_filter_shift.tooltip = 'Y filter shift of the color enlarger from a neutral position, enlarger has 170 steps'
simulation.print_m_filter_shift.tooltip = 'M filter shift of the color enlarger from a neutral position, enlarger has 170 steps'
# simulation.print_lens_blur.tooltip = 'Sigma of gaussian filter in pixel for the print lens blur'
simulation.scan_lens_blur.tooltip = 'Sigma of gaussian filter in pixel for the scanner lens blur'
simulation.scan_unsharp_mask.tooltip = 'Apply unsharp mask to the scan, [sigma in pixel, amount]'
simulation.output_color_space.tooltip = 'Color space of the output image'
simulation.output_cctf_encoding.tooltip = 'Apply the cctf transfer function of the color space. If false, data is linear.'
simulation.compute_negative.tooltip = 'Show a scan of the negative instead of the print'
simulation.compute_full_image.tooltip = 'Do not apply preview resize, compute full resolution image. Keeps the crop if active.'
simulation.call_button.tooltip = 'Run the simulation. Note: grain and halation computed only when compute_full_image is clicked.'

special.film_gamma_factor.tooltip = 'Gamma factor of the density curves of the negative, < 1 reduce contrast, > 1 increase contrast'
special.print_gamma_factor.tooltip = 'Gamma factor of the print paper, < 1 reduce contrast, > 1 increase contrast'
special.print_gamma_factor.step = 0.05
special.print_density_min_factor.tooltip = 'Minimum density factor of the print paper (0-1), make the white less white'
special.print_density_min_factor.min = 0
special.print_density_min_factor.step = 0.2
special.print_density_min_factor.max = 1

glare.active.tooltip = 'Add glare to the print'
glare.percent.tooltip = 'Percentage of the glare light (typically 0.1-0.25)'
glare.percent.step = 0.05
glare.roughness.tooltip = 'Roughness of the glare light (0-1)'
glare.blur.tooltip = 'Sigma of gaussian blur in pixels for the glare'
glare.compensation_removal_factor.tooltip = 'Factor of glare compensation removal from the print, e.g. 0.2=20% underexposed print in the shadows, typical values (0.0-0.2). To be used instead of stochastic glare (i.e. when percent=0).'
glare.compensation_removal_factor.step = 0.05
glare.compensation_removal_density.tooltip = 'Density of the glare compensation removal from the print, typical values (1.0-1.5).'
glare.compensation_removal_transition.tooltip = 'Transition density range of the glare compensation removal from the print, typical values (0.1-0.5).'

halation.scattering_strength.tooltip = 'Fraction of scattered light (0-100, percentage) for each channel [R,G,B]'
halation.scattering_size_um.tooltip = 'Size of the scattering effect in micrometers for each channel [R,G,B], sigma of gaussian filter.'
halation.halation_strength.tooltip = 'Fraction of halation light (0-100, percentage) for each channel [R,G,B]'
halation.halation_size_um.tooltip = 'Size of the halation effect in micrometers for each channel [R,G,B], sigma of gaussian filter.'

couplers.dir_couplers_amount.tooltip = 'Amount of coupler inhibitors, control saturation, typical values (0.8-1.2).'
couplers.dir_couplers_amount.step = 0.05
couplers.dir_couplers_diffusion_um.tooltip = 'Sigma in um for the diffusion of the couplers, (5-20 um), controls sharpness and affects saturation.'
couplers.dir_couplers_diffusion_um.step = 5
couplers.diffusion_interlayer.tooltip = 'Sigma in number of layers for diffusion across the rgb layers (typical layer thickness 3-5 um, so roughly 1.0-4.0 layers), affects saturation.'

grain.active.tooltip = 'Add grain to the negative'
grain.particle_area_um2.tooltip = 'Area of the particles in um2, relates to ISO. Approximately 0.1 for ISO 100, 0.1 for ISO 200, 0.4 for ISO 400 and so on.'
grain.particle_area_um2.step = 0.1
grain.particle_scale.tooltip = 'Scale of particle area for the RGB layers, multiplies particle_area_um2'
grain.particle_scale_layers.tooltip = 'Scale of particle area for the sublayers in every color layer, multiplies particle_area_um2'
grain.density_min.tooltip = 'Minimum density of the grain, typical values (0.03-0.06)'
grain.uniformity.tooltip = 'Uniformity of the grain, typical values (0.94-0.98)'
grain.blur.tooltip = 'Sigma of gaussian blur in pixels for the grain, to be increased at high magnifications, (should be 0.8-0.9 at high resolution, reduce down to 0.6 for lower res).'
grain.blur_dye_clouds_um.tooltip = 'Scale the sigma of gaussian blur in um for the dye clouds, to be used at high magnifications, (default 1)'
grain.micro_structure.tooltip = 'Parameter for micro-structure due to clumps at the molecular level, [sigma blur of micro-structure / ultimate light-resolution (0.10 um default), size of molecular clumps in nm (30 nm default)]. Only for insane magnifications.'

preflashing.exposure.tooltip = 'Preflash exposure value in ev for the print'
preflashing.just_preflash.tooltip = 'Only apply preflash to the print, to visualize the preflash effect'
preflashing.y_filter_shift.tooltip = 'Shift the Y filter of the enlarger from the neutral position for the preflash, typical values (-20-20), enlarger has 170 steps'
preflashing.m_filter_shift.tooltip = 'Shift the M filter of the enlarger from the neutral position for the preflash, typical values (-20-20), enlarger has 170 steps'
preflashing.exposure.step = 0.005
preflashing.y_filter_shift.min = -ENLARGER_STEPS
preflashing.m_filter_shift.min = -ENLARGER_STEPS

input_image.preview_resize_factor.tooltip = 'Scale image size down (0-1) to speed up preview processing'
input_image.crop.tooltip = 'Crop image to a fraction of the original size to preview details at full scale'
input_image.crop_center.tooltip = 'Center of the crop region in relative coordinates in x, y (0-1)'
input_image.crop_size.tooltip = 'Normalized size of the crop region in x, y (0,1), as fraction of the long side.'
input_image.input_color_space.tooltip = 'Color space of the input image, will be internally converted to sRGB and negative values clipped'
input_image.apply_cctf_decoding.tooltip = 'Apply the inverse cctf transfer function of the color space'
input_image.upscale_factor.tooltip = 'Scale image size up to increase resolution'
input_image.spectral_upsampling_method.tooltip = 'Method to upsample the spectral resolution of the image, hanatos2025 works on the full visible locus, mallett2019 works only on sRGB (will clip input).'
input_image.filter_uv.tooltip = 'Filter UV light, (amplitude, wavelength cutoff in nm, sigma in nm). It mainly helps for avoiding UV light ruining the reds. Changing this enlarger filters neutral will be affected.'
input_image.filter_ir.tooltip = 'Filter IR light, (amplitude, wavelength cutoff in nm, sigma in nm). Changing this enlarger filters neutral will be affected.'

# tab1 = Container(layout='vertical', widgets=[grain, preflashing])
viewer.window.add_dock_widget(input_image, area="right", name='input', tabify=True)
# viewer.window.add_dock_widget(curves, area="right", name='curves', tabify=True)
viewer.window.add_dock_widget(halation, area="right", name='halation', tabify=True)
viewer.window.add_dock_widget(couplers, area="right", name='couplers', tabify=True)
viewer.window.add_dock_widget(grain, area="right", name='grain', tabify=True)
viewer.window.add_dock_widget(preflashing, area="right", name='preflash', tabify=True)
viewer.window.add_dock_widget(glare, area="right", name='glare', tabify=True)
viewer.window.add_dock_widget(special, area="right", name='special', tabify=True)
viewer.window.add_dock_widget(layer_list, area="right", name='layers', tabify=True)
viewer.window.add_dock_widget(filepicker, area="right", name='filepicker', tabify=True)
viewer.window.add_dock_widget(simulation, area="right", name='main', tabify=False)
napari.run()

# TODO: use magicclass to create collapsable widgets as in https://forum.image.sc/t/widgets-alignment-in-the-plugin-when-nested-magic-class-and-magicgui-are-used/62929 