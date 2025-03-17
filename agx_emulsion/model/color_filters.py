import numpy as np
import scipy
import colour
import scipy.interpolate
import matplotlib.pyplot as plt
from agx_emulsion.config import SPECTRAL_SHAPE, ENLARGER_STEPS
from agx_emulsion.utils.io import load_dichroic_filters, load_filter

################################################################################
# Color Filter class
################################################################################

def create_combined_dichroic_filter(wavelength,
                                    filtering_amount_percent,
                                    transitions,
                                    edges,
                                    nd_filter=0,
                                    ):
    # data from https://qd-europe.com/se/en/product/dichroic-filters-and-sets/
    dichroics = np.zeros((3, np.size(wavelength)))
    dichroics[0] = scipy.special.erf( (wavelength-edges[0])/transitions[0])
    dichroics[1][wavelength<=550] = -scipy.special.erf( (wavelength[wavelength<=550]-edges[1])/transitions[1])
    dichroics[1][wavelength>550] = scipy.special.erf( (wavelength[wavelength>550]-edges[2])/transitions[2])
    dichroics[2] = -scipy.special.erf( (wavelength-edges[3])/transitions[3])
    dichroics = dichroics/2 + 0.5
    filtering_amount = np.array(filtering_amount_percent)/100.0
    total_filter = np.prod(((1-filtering_amount[:,None]) + dichroics*filtering_amount[:, None]),axis = 0)
    total_filter *=(100-nd_filter)/100
    return total_filter

def filterset(illuminant,
              values=[0, 0, 0],
              edges=[510,495,605,590],
              transitions=[10,10,10,10],
              ):
    total_filter = create_combined_dichroic_filter(illuminant.wavelengths,
                                                  filtering_amount_percent=values,
                                                  transitions=transitions,
                                                  edges=edges)
    values = illuminant*total_filter
    filtered_illuminant = colour.SpectralDistribution(values, domain=SPECTRAL_SHAPE)
    return filtered_illuminant

class DichroicFilters():
    def __init__(self,
                 brand='thorlabs'):
        self.wavelengths = SPECTRAL_SHAPE.wavelengths
        self.filters = np.zeros((np.size(self.wavelengths), 3))
        self.filters = load_dichroic_filters(self.wavelengths, brand)
            
    def plot(self):
        colors = ['gold', 'tab:pink', 'tab:cyan']
        _, ax = plt.subplots()
        for i in range(3):
            ax.plot(self.wavelengths, self.filters[:,i], color=colors[i])
        ax.set_ylabel('Transmittance')
        ax.set_xlabel('Wavelegnth (nm)')
        ax.set_ylim(0,1)
        ax.set_xlim(np.min(self.wavelengths), np.max(self.wavelengths))
        ax.legend(('Y','M','C'))
    
    def apply(self, illuminant, values=[0,0,0]):
        dimmed_filters = 1 - (1-self.filters)*np.array(values) # following durst 605 wheels values, with 170 max
        total_filter = np.prod(dimmed_filters, axis=1)
        filtered_illuminant = illuminant*total_filter
        return filtered_illuminant

class GenericFilter():
    def __init__(self,
                 name='KG3',
                 type='heat_absorbing',
                 brand='schott',
                 data_in_percentage=False,
                 load_from_database=True):
        self.wavelengths = SPECTRAL_SHAPE.wavelengths
        self.type = type
        self.brand = brand
        self.transmittance = np.zeros_like(self.wavelengths)
        if load_from_database:
            self.transmittance = load_filter(self.wavelengths, name, brand, type,
                                             percent_transmittance=data_in_percentage)
    
    def apply(self, illuminant, value=1.0):
        dimmed_filter = 1 - (1-self.transmittance)*value
        filtered_illuminant = illuminant*dimmed_filter
        return filtered_illuminant

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
        

# color filter variables
dichroic_filters = DichroicFilters()
thorlabs_dichroic_filters = DichroicFilters(brand='thorlabs')
edmund_optics_dichroic_filters = DichroicFilters(brand='edmund_optics')
durst_digital_light_dicrhoic_filters = DichroicFilters(brand='durst_digital_light')
schott_kg1_heat_filter = GenericFilter(name='KG1', type='heat_absorbing', brand='schott')
schott_kg3_heat_filter = GenericFilter(name='KG3', type='heat_absorbing', brand='schott')
schott_kg5_heat_filter = GenericFilter(name='KG5', type='heat_absorbing', brand='schott')
generic_lens_transmission = GenericFilter(name='canon_24_f28_is', type='lens_transmission',
                                          brand='canon', data_in_percentage=True)


################################################################################

def color_enlarger(light_source, y_filter_value, m_filter_value, c_filter_value=0,
                   enlarger_steps=ENLARGER_STEPS,
                   filters=durst_digital_light_dicrhoic_filters):
    ymc_filter_values = np.array([y_filter_value, m_filter_value, c_filter_value]) / enlarger_steps
    filtered_illuminant = filters.apply(light_source, values=ymc_filter_values)
    return filtered_illuminant

if __name__=="__main__":
    from agx_emulsion.model.illuminants import standard_illuminant
    
    filters = DichroicFilters(brand='durst_digital_light')
    filters.plot()
    plt.title('Durst Digital Light Dichroic Filters')
    
    filters = DichroicFilters(brand='thorlabs')
    filters.plot()
    plt.title('Thorlabs Dichroic Filters')
    
    filters = DichroicFilters(brand='edmund_optics')
    filters.plot()
    plt.title('Edmund Optics Dichroic Filters')
    
    plt.figure()
    d65 = standard_illuminant('D55')
    # plt.plot(SPECTRAL_SHAPE.wavelengths, d65)
    # plt.plot(SPECTRAL_SHAPE.wavelengths, filters.apply(d65, [0.8,0.0,0])[:])
    plt.plot(SPECTRAL_SHAPE.wavelengths, schott_kg3_heat_filter.transmittance)
    plt.plot(SPECTRAL_SHAPE.wavelengths, generic_lens_transmission.transmittance)
    plt.plot(SPECTRAL_SHAPE.wavelengths, schott_kg3_heat_filter.transmittance*generic_lens_transmission.transmittance)
    plt.ylim((0,1))
    plt.xlabel('Wavelength (nm)')
    plt.ylabel('Intensity')
    plt.legend(('Schott KG3', 'Canon Lens Transmittance', 'Combined'))
    
    plt.show()