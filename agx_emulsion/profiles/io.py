import json
import copy
import numpy as np
from dotmap import DotMap
import importlib.resources as pkg_resources

def save_profile(profile, suffix=''):
    profile.info.stock = profile.info.stock + suffix
    profile = copy.copy(profile)
    # convert to lists to make it json serializable
    profile.data.log_sensitivity       = profile.data.log_sensitivity.tolist()
    profile.data.density_curves        = profile.data.density_curves.tolist()
    profile.data.density_curves_layers = profile.data.density_curves_layers.tolist()
    profile.data.dye_density           = profile.data.dye_density.tolist()
    profile.data.log_exposure          = profile.data.log_exposure.tolist()
    profile.data.wavelengths           = profile.data.wavelengths.tolist()
    package = pkg_resources.files('agx_emulsion.data.profiles')
    filename = profile.info.stock + '.json'
    resource = package / filename
    print('Saving to:', filename)
    with resource.open("w") as file:
        json.dump(profile.toDict(), file, indent=4)

def load_profile(stock):
    package = pkg_resources.files('agx_emulsion.data.profiles')
    filename = stock + '.json'
    resource = package / filename
    profile = DotMap()
    with resource.open("r") as file:
        profile = DotMap(json.load(file))
    profile.data.log_sensitivity = np.array(profile.data.log_sensitivity)
    profile.data.dye_density = np.array(profile.data.dye_density)
    profile.data.density_curves = np.array(profile.data.density_curves)
    profile.data.log_exposure = np.array(profile.data.log_exposure)
    profile.data.wavelengths = np.array(profile.data.wavelengths)
    profile.data.density_curves_layers = np.array(profile.data.density_curves_layers)
    return profile