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
        _, ax = plt.subplots()
        ax.plot(self.wavelengths, self.filters)
        ax.set_ylabel('Transmittance')
        ax.set_xlabel('Wavelegnth (nm)')
        ax.set_ylim(0,1)
        ax.legend(('y','m','c'))
    
    def apply(self, illuminant, values=[0,0,0]):
        dimmed_filters = 1 - (1-self.filters)*np.array(values) # following durst 605 wheels values, with 170 max
        total_filter = np.prod(dimmed_filters, axis=1)
        filtered_illuminant = illuminant*total_filter
        return filtered_illuminant

class GenericFilter():
    def __init__(self,
                 name='KG3',
                 type='heat_absorbing',
                 brand='schott'):
        self.wavelengths = SPECTRAL_SHAPE.wavelengths
        self.type = type
        self.brand = brand
        self.transmittance = load_filter(self.wavelengths, name, brand, type)
    
    def apply(self, illuminant, value=1.0):
        dimmed_filter = 1 - (1-self.transmittance)*value
        filtered_illuminant = illuminant*dimmed_filter
        return filtered_illuminant

# color filter variables
dichroic_filters = DichroicFilters()
thorlabs_dichroic_filters = DichroicFilters(brand='thorlabs')
edmund_optics_dichroic_filters = DichroicFilters(brand='edmund_optics')
durst_digital_light_dicrhoic_filters = DichroicFilters(brand='durst_digital_light')
schott_kg1_heat_filter = GenericFilter(name='KG1', type='heat_absorbing', brand='schott')
schott_kg3_heat_filter = GenericFilter(name='KG3', type='heat_absorbing', brand='schott')
schott_kg5_heat_filter = GenericFilter(name='KG5', type='heat_absorbing', brand='schott')


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
    
    plt.figure()
    d65 = standard_illuminant('D55')
    plt.plot(SPECTRAL_SHAPE.wavelengths, d65)
    plt.plot(SPECTRAL_SHAPE.wavelengths, filters.apply(d65, [0.8,0.0,0])[:])
    plt.xlabel('Wavelength (nm)')
    plt.ylabel('Intensity')
    plt.legend(('Illuminant', 'Filtered Illuminant'))
    
    plt.show()