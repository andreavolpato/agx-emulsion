import numpy as np

def parametric_density_curves_model(log_exposure, gamma, log_exposure_0, density_max, toe_size, shoulder_size):
    density_curves = np.zeros((np.size(log_exposure), 3))
    for i, g, loge0, dmax, ts, ss in zip(np.arange(3),
                                            gamma, log_exposure_0, density_max, toe_size, shoulder_size):
        density_curves[:,i] = (  
              g*ts * np.log10(1 + 10**( (log_exposure - loge0         )/ts ))
            - g*ss * np.log10(1 + 10**( (log_exposure - loge0 - dmax/g)/ss ))
        )
    return density_curves