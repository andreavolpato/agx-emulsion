import json
import copy
import numpy as np
from types import SimpleNamespace
import importlib.resources as pkg_resources


class ProfileNamespace(SimpleNamespace):
    def __getattr__(self, name):
        if name.startswith('__'):
            raise AttributeError(name)
        value = ProfileNamespace()
        setattr(self, name, value)
        return value


def profile_from_dict(data):
    if isinstance(data, dict):
        return ProfileNamespace(**{k: profile_from_dict(v) for k, v in data.items()})
    if isinstance(data, list):
        return [profile_from_dict(v) for v in data]
    if isinstance(data, tuple):
        return tuple(profile_from_dict(v) for v in data)
    return data


def profile_to_dict(data):
    if isinstance(data, dict):
        return {k: profile_to_dict(v) for k, v in data.items()}
    if isinstance(data, list):
        return [profile_to_dict(v) for v in data]
    if isinstance(data, tuple):
        return [profile_to_dict(v) for v in data]
    if hasattr(data, '__dict__'):
        return {k: profile_to_dict(v) for k, v in vars(data).items()}
    return data


def _validate_profile(profile, stock):
    try:
        data = profile.data
        valid = (
            data.log_exposure.ndim == 1
            and data.density_curves.ndim == 2
            and data.density_curves.shape[1] == 3
            and data.density_curves.shape[0] == data.log_exposure.shape[0]
            and data.log_sensitivity.ndim == 2
            and data.log_sensitivity.shape[1] == 3
            and data.wavelengths.ndim == 1
            and data.dye_density.ndim == 2
            and data.dye_density.shape[0] == data.wavelengths.shape[0]
            and data.dye_density.shape[1] >= 4
        )
    except (AttributeError, IndexError, KeyError, TypeError):
        raise ValueError(f"Invalid profile '{stock}'") from None

    if not valid:
        raise ValueError(f"Invalid profile '{stock}'")

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
        json.dump(profile_to_dict(profile), file, indent=4)

def load_profile(stock):
    package = pkg_resources.files('agx_emulsion.data.profiles')
    filename = stock + '.json'
    resource = package / filename
    with resource.open("r") as file:
        profile = profile_from_dict(json.load(file))
    profile.data.log_sensitivity = np.array(profile.data.log_sensitivity)
    profile.data.dye_density = np.array(profile.data.dye_density)
    profile.data.density_curves = np.array(profile.data.density_curves)
    profile.data.log_exposure = np.array(profile.data.log_exposure)
    profile.data.wavelengths = np.array(profile.data.wavelengths)
    profile.data.density_curves_layers = np.array(profile.data.density_curves_layers)
    _validate_profile(profile, stock)
    return profile