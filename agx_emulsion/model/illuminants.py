import numpy as np
import colour
from agx_emulsion.config import SPECTRAL_SHAPE, STANDARD_OBSERVER_CMFS


def standard_illuminant(type='D65', return_class=False):
    if type[0:2]=='BB':
        temperature = np.double(type[2:])
        values = colour.colorimetry.blackbody.planck_law(SPECTRAL_SHAPE.wavelengths*1e-9, temperature) # to emulate an halogen lamp
        spectral_intensity = colour.SpectralDistribution(values, domain=SPECTRAL_SHAPE, label=type)
    elif type=='T':
        spectral_intensity = colour.SDS_LIGHT_SOURCES['Incandescent'].copy().align(SPECTRAL_SHAPE)
    elif type=='K75P':
        spectral_intensity = colour.SDS_LIGHT_SOURCES['Kinoton 75P'].copy().align(SPECTRAL_SHAPE)
    else:
        spectral_intensity = colour.SDS_ILLUMINANTS[type].copy().align(SPECTRAL_SHAPE)
    normalization = np.sum(spectral_intensity[:] * STANDARD_OBSERVER_CMFS[:,1])
    spectral_intensity /= normalization
    spectral_intensity.name = type
    if return_class:
        return spectral_intensity
    else:
        return spectral_intensity[:]


if __name__=="__main__":
    d65 = standard_illuminant('LED-RGB1', return_class=True)
    print(d65.name)
