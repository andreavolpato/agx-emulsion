import numpy as np
import scipy
import scipy.ndimage
from agx_emulsion.utils.fast_stats import fast_binomial, fast_poisson, fast_lognormal_from_mean_std
# from agx_emulsion.utils.fast_gaussian_filter import fast_gaussian_filter

################################################################################
# Grain (very simple model)
################################################################################

def layer_particle_model(density,
                         density_max=2.2,
                         n_particles_per_pixel=10,
                         grain_uniformity=0.98,
                         seed=None,
                         blur_particle=0.0,
                         method='poisson_binomial',
                         use_fast_stats=False,
                         ):
    if seed is not None:
        np.random.seed(seed) # scipy uses np.random
    
    probability_of_development = density/density_max
    probability_of_development = np.clip(probability_of_development, 1e-6, 1-1e-6) # for safe calc
    od_particle = density_max/n_particles_per_pixel
    
    grain = np.zeros_like(density)
    if method=='gamma_beta':
        gamma_rvs = scipy.stats.gamma.rvs
        beta_rvs = scipy.stats.beta.rvs
        seeds = gamma_rvs(n_particles_per_pixel/(1-grain_uniformity+1e-6), size=density.shape) * (1-grain_uniformity+1e-6)
        grain = beta_rvs(probability_of_development*n_particles_per_pixel,
                        (1-probability_of_development)*n_particles_per_pixel)*seeds*od_particle
    elif method=='poisson_binomial':
        if use_fast_stats:
            binom_rvs = fast_binomial
            poisson_rvs = fast_poisson
        else:
            binom_rvs = scipy.stats.binom.rvs
            poisson_rvs = scipy.stats.poisson.rvs
        saturation = 1 - probability_of_development*grain_uniformity*(1-1e-6)
        seeds = poisson_rvs(n_particles_per_pixel/saturation)
        grain = binom_rvs(seeds, probability_of_development)
        grain = np.double(grain)*od_particle*saturation
    
    if blur_particle>0:
        grain = scipy.ndimage.gaussian_filter(grain, blur_particle*np.sqrt(od_particle))
        # grain = fast_gaussian_filter(grain, blur_particle*np.sqrt(od_particle))
    return grain

def add_micro_structure(density_cmy_out, micro_structure, pixel_size_um):
    grain_micro_structure_blur_pixel = micro_structure[0]/pixel_size_um
    grain_micro_structure_sigma = micro_structure[1]*0.001/pixel_size_um  # grain microstructure[1] is in nm
    if grain_micro_structure_sigma > 0.05:
        clumping = fast_lognormal_from_mean_std(np.ones_like(density_cmy_out),
                                                np.ones_like(density_cmy_out)*grain_micro_structure_sigma)
        if grain_micro_structure_blur_pixel>0.4:
            clumping = scipy.ndimage.gaussian_filter(clumping, (grain_micro_structure_blur_pixel,
                                                                grain_micro_structure_blur_pixel, 0))
        density_cmy_out *= clumping
    return density_cmy_out

def apply_grain_to_density(density_cmy,
                           pixel_size_um=10,
                           agx_particle_area_um2=0.2,
                           agx_particle_scale=[1,0.8,3],
                           density_min=[0.03,0.06,0.04],
                           density_max_curves=[2.2,2.2,2.2],
                           grain_uniformity=[0.98,0.98,0.98],
                           grain_blur=1.0,
                           n_sub_layers=1,
                           fixed_seed=None,
                           ):
    density_min = np.array(density_min)
    density_max = density_max_curves + density_min
    pixel_area_um2 = pixel_size_um**2
    agx_particle_area_um2 = agx_particle_area_um2*np.array(agx_particle_scale)
    n_particles_per_pixel = pixel_area_um2/agx_particle_area_um2
    sigma_blur_pixel = grain_blur
    
    if fixed_seed is not None:
        seed = None
    else:
        seed = [0, 1, 2]
    
    if n_sub_layers>1:
        n_particles_per_pixel /= n_sub_layers
    
    density_cmy += density_min
    density_cmy_out = np.zeros_like(density_cmy)
    for ch in np.arange(3):
        for sl in np.arange(n_sub_layers):
            density_cmy_out[:,:,ch] += layer_particle_model(density_cmy[:,:,ch],
                                                            density_max=density_max[ch],
                                                            n_particles_per_pixel=n_particles_per_pixel[ch],
                                                            grain_uniformity=grain_uniformity[ch],
                                                            seed=seed[ch] + sl*10)
    density_cmy_out /= n_sub_layers
    density_cmy_out -= density_min
    
    if sigma_blur_pixel>0.4:
        density_cmy_out = scipy.ndimage.gaussian_filter(density_cmy_out, (sigma_blur_pixel, sigma_blur_pixel, 0))
        
    return density_cmy_out


# experimental
def apply_grain_to_density_layers(density_cmy_layers, # x,y,sublayers,rgb
                                  density_max_layers, # 3x3 [sublayers,rgb]
                                  pixel_size_um=10,
                                  agx_particle_area_um2=0.2,
                                  agx_particle_scale=[1,0.8,3], # rgb
                                  agx_particle_scale_layers=[3,1,0.3], # sublayers
                                  density_min=[0.03,0.06,0.04],
                                  grain_uniformity=[0.98,0.98,0.98],
                                  grain_blur=1.0,
                                  grain_blur_dye_clouds_um=1.0,
                                  grain_micro_structure=(0.1, 30),
                                  fixed_seed=None,
                                  use_fast_stats=False,
                                  ):
    density_max_total = np.sum(density_max_layers, axis=0) # [sublayers,rgb]
    density_max_fractions = density_max_layers/density_max_total[None,:]
    density_min_layers = density_max_fractions*np.array(density_min)[None,:]
    density_max_layers = density_max_layers + density_min_layers
    
    pixel_area_um2 = pixel_size_um**2
    agx_particle_area_um2_layers = (agx_particle_area_um2 * 
                                    np.array(agx_particle_scale)[None,:] * 
                                    np.array(agx_particle_scale_layers)[:,None]) # layers, rgb
    n_particles_per_pixel = pixel_area_um2*density_max_fractions/agx_particle_area_um2_layers

    
    if fixed_seed is not None:
        seed = None
    else:
        seed = [0, 1, 2]
    
    density_cmy_layers += density_min_layers
    density_cmy_out = np.zeros(density_cmy_layers.shape[0:3])
    for ch in np.arange(3): # rgb channels
        for sl in np.arange(3): # sublayers
            density_cmy_out[:,:,ch] += layer_particle_model(density_cmy_layers[:,:,sl,ch],
                                                            density_max=density_max_layers[sl,ch],
                                                            n_particles_per_pixel=n_particles_per_pixel[sl,ch],
                                                            grain_uniformity=grain_uniformity[ch],
                                                            seed=seed[ch] + sl*10,
                                                            blur_particle=grain_blur_dye_clouds_um,
                                                            use_fast_stats=use_fast_stats)
    
    # micro-structure
    density_cmy_out = add_micro_structure(density_cmy_out, grain_micro_structure, pixel_size_um)

    # final
    density_cmy_out -= density_min
    if grain_blur>0:
        density_cmy_out = scipy.ndimage.gaussian_filter(density_cmy_out, (grain_blur, grain_blur, 0))
        # density_cmy_out = fast_gaussian_filter(density_cmy_out, grain_blur)
    return density_cmy_out

# TODO: make grain parameter with RMS granularity

if __name__=='__main__':
    density = np.ones((128,128))*2
    g1 = layer_particle_model(density, density_max=2, n_particles_per_pixel=10, grain_uniformity=0.99, sigma_blur=0.)
    g2 = layer_particle_model(density, density_max=2, n_particles_per_pixel=10, grain_uniformity=0.96, sigma_blur=0.)
    print('g1 ------------------')
    print('Density Test')
    print('Mean', np.mean(g1))
    print('RMS', np.std(g1)*1000)
    print('Skewness', scipy.stats.skew(g1.flatten()))
    print('Kurtosis', scipy.stats.kurtosis(g1.flatten()))
    print('g2 ------------------')
    print('Mean', np.mean(g2))
    print('RMS', np.std(g2)*1000)
    print('Skewness', scipy.stats.skew(g2.flatten()))
    print('Kurtosis', scipy.stats.kurtosis(g2.flatten()))
    import matplotlib.pyplot as plt
    fig, axs = plt.subplots(1,2)
    axs[0].imshow(g1, vmin=0, vmax=2.2)
    axs[0].set_title('Uniformity=0.99')
    axs[1].imshow(g2, vmin=0, vmax=2.2)
    axs[1].set_title('Uniformity=0.96')
    fig.suptitle('Fully saturated density with different uniformity')
    plt.show()