import numpy as np
import matplotlib.pyplot as plt
from agx_emulsion.profiles.io import load_profile
from agx_emulsion.model.process import photo_params, photo_process

def plot_grain_chart(profile=load_profile('kodak_portra_400_auc'),
                     film_format_mm=35):
    
    # make test chart
    log_exposure_gradient = profile.data.log_exposure + np.log10(0.184)
    exposure = 10**log_exposure_gradient
    image = np.tile(exposure, (2048, 1))
    image = np.tile(image,  (3,1,1))
    image = np.transpose(image, (1,2,0))
    
    densitometer_aperture_diameter = 48 # um
    pixel_size = np.sqrt((densitometer_aperture_diameter/2)**2*np.pi)
    film_format_mm = np.max(image.shape) * pixel_size / 1000

    p = photo_params()
    p.negative = profile
    p.camera.film_format_mm = film_format_mm
    p.io.input_cctf_decoding = False
    p.camera.auto_exposure = False
    p.camera.exposure_compensation_ev = 0
    p.io.compute_negative = True
    p.debug.deactivate_spatial_effects = True
    p.debug.return_negative_density_cmy = True
    density_cmy = photo_process(image, p)
    
    rms = np.std(density_cmy, axis=0)*1000
    
    # plot
    fig, ax2 = plt.subplots()
    colors = ['tab:red', 'tab:green', 'tab:blue']
    for i in np.arange(3):
        ax2.plot(profile.data.log_exposure, profile.data.density_curves[:,i], color=colors[i])

    ax2.set_ylim((0,3))
    ax2.set_xlim((-2,3))
    ax2.set_ylabel('Unmixed Density (over B+F)')
    ax2.legend(['R', 'G', 'B'])
    ax2.set_xlabel('Log Exposure')
    ax2.set_title('Diffuse RMS Granularity Curves')
    ax1 = ax2.twinx()

    for i in np.arange(3):
        ax1.plot(log_exposure_gradient-np.log10(0.184), rms[:,i], '--', color=colors[i])
    ax1.set_ylim((1, 1000))
    ax1.set_yscale('log')
    ax1.set_yticks([1,2,3,5,10,20,30,50,100],[1,2,3,5,10,20,30,50,100])
    ax1.grid(alpha=0.25)
    ax1.set_ylabel('Granularity Sigma D x1000')

    
    ax1.text(0.16, 0.95, profile.info.name, transform=ax1.transAxes, ha='left', va='center')
    ax1.text(0.16, 0.90, f'Particle area: {profile.grain.agx_particle_area_um2} $\mu$m$^2$', transform=ax1.transAxes, ha='left', va='center')
    ax1.text(0.16, 0.85, f'Particle area scale RGB: {profile.grain.agx_particle_scale}', transform=ax1.transAxes, ha='left', va='center')
    ax1.text(0.16, 0.80, f'Particle area scale sublayers: {profile.grain.agx_particle_scale_layers}', transform=ax1.transAxes, ha='left', va='center')
    ax1.text(0.16, 0.75, f'Uniformity RGB: {profile.grain.uniformity}', transform=ax1.transAxes, ha='left', va='center')
    ax1.text(0.16, 0.70, f'Density min RGB: {profile.grain.density_min}', transform=ax1.transAxes, ha='left', va='center')

    
if __name__=='__main__':
    profile=load_profile('kodak_vision3_50d_uc')
    profile.grain.agx_particle_area_um2 = 0.1
    profile.grain.agx_particle_scale = [1.2,1,2.5] # particle scale rgb
    profile.grain.agx_particle_scale_layers = [6,1,0.4] # particle scale sublayers
    profile.grain.uniformity = [0.99, 0.97, 0.98]
    profile.grain.density_min = [0.04,0.05,0.06]
    plot_grain_chart(profile)
    plt.savefig('grain_chart_kodak_vision3_50d.png', dpi=300)
    plt.show()