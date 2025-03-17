import numpy as np
import colour
from agx_emulsion.config import SPECTRAL_SHAPE
from agx_emulsion.model.color_filters import schott_kg3_heat_filter, schott_kg1_heat_filter, generic_lens_transmission

def black_body_spectrum(temperature):
    values = colour.colorimetry.blackbody.planck_law(SPECTRAL_SHAPE.wavelengths*1e-9, temperature) # to emulate an halogen lamp
    spectral_intensity = colour.SpectralDistribution(values, domain=SPECTRAL_SHAPE)
    return spectral_intensity

def standard_illuminant(type='D65', return_class=False):
    if type[0:2]=='BB':
        temperature = np.double(type[2:])
        spectral_intensity = black_body_spectrum(temperature)
    elif type=='T':
        spectral_intensity = colour.SDS_LIGHT_SOURCES['Incandescent'].copy().align(SPECTRAL_SHAPE)
    elif type=='K75P':
        spectral_intensity = colour.SDS_LIGHT_SOURCES['Kinoton 75P'].copy().align(SPECTRAL_SHAPE)
    elif type=='TH-KG3':
        spectral_intensity = black_body_spectrum(3200)
        spectral_intensity.values = schott_kg3_heat_filter.apply(spectral_intensity.values)
    elif type=='TH-KG3-L': # enlarger source with heat filter and lens transmittance
        spectral_intensity = black_body_spectrum(3200)
        spectral_intensity.values = schott_kg3_heat_filter.apply(spectral_intensity.values)
        spectral_intensity.values = generic_lens_transmission.apply(spectral_intensity.values)
    else:
        spectral_intensity = colour.SDS_ILLUMINANTS[type].copy().align(SPECTRAL_SHAPE)
    spectral_intensity.name = type
    # normalization
    normalization = np.sum(spectral_intensity.values) / np.size(SPECTRAL_SHAPE.wavelengths)
    spectral_intensity.values = spectral_intensity.values / normalization
    
    if return_class:
        return spectral_intensity
    else:
        return spectral_intensity[:]


if __name__=="__main__":
    import matplotlib.pyplot as plt
    ill = standard_illuminant('D55-KG3', return_class=True)
    print(ill[:])
    plt.plot(ill.wavelengths, ill.values)
    plt.show()
