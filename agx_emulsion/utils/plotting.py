import numpy as np
import matplotlib.pyplot as plt

# NOTE: this file will not work at the moment, it is just a draft

def plot(self):
    fig, axs = plt.subplots(1,3)
    fig.set_tight_layout(tight='rect')
    fig.set_figheight(4)
    fig.set_figwidth(12)
    axs[0].plot(self.wavelengths, np.log10(self.sensitivity[:,0]), color='tab:red')
    axs[0].plot(self.wavelengths, np.log10(self.sensitivity[:,1]), color='tab:green')
    axs[0].plot(self.wavelengths, np.log10(self.sensitivity[:,2]), color='tab:blue')
    axs[0].legend(('R','G','B'))
    axs[0].set_xlabel('Wavelength (nm)')
    axs[0].set_ylabel('Log Sensitivity')
    axs[0].set_xlim((350, 750))
    
    # H_ref = 0
    # D_lim = np.max(self.density_curves.data)*1.05
    axs[1].plot(self.density_curves.log_exposure, self.density_curves.data[:,0], color='tab:red')
    axs[1].plot(self.density_curves.log_exposure, self.density_curves.data[:,1], color='tab:green')
    axs[1].plot(self.density_curves.log_exposure, self.density_curves.data[:,2], color='tab:blue')
    # axs[1].plot([H_ref, H_ref], [0, D_lim], color='gray', linewidth=1)
    # axs[1].plot([H_ref+1, H_ref+1], [0, D_lim], color='lightgray', linestyle='dashed', linewidth=1)
    # axs[1].plot([H_ref-1.67, H_ref-1.67], [0, D_lim], color='lightgray', linestyle='dashed', linewidth=1)
    axs[1].legend(('R','G','B','Ref'))
    axs[1].set_xlabel('Log Exposure')
    axs[1].set_ylabel('Density')
    # axs[1].set_ylim(0, D_lim)
    
    axs[2].plot([350, 750], [0,0], color='gray', linewidth=1, label='_nolegend_')
    axs[2].plot(self.wavelengths, self.dye_density[:,0], color='tab:cyan')
    axs[2].plot(self.wavelengths, self.dye_density[:,1], color='tab:pink')
    axs[2].plot(self.wavelengths, self.dye_density[:,2], color='gold')
    if self.type=='negative':
        axs[2].plot(self.wavelengths, self.dye_density[:,3], color='gray', linewidth=1)
        axs[2].plot(self.wavelengths, self.dye_density[:,4], color='lightgray', linewidth=1)
        axs[2].legend(('C','M','Y','Min','Mid','Sim'))
    else:
        axs[2].legend(('C','M','Y'))
    axs[2].set_xlabel('Wavelength (nm)')
    axs[2].set_ylabel('Diffuse Density')
    axs[2].set_xlim((350, 750))
    
def print_filter_test(self, emulsion, print_illuminant, viewing_illuminant,
                        y_filter=70,
                        y_filter_spread=30,
                        m_filter=40,
                        m_filter_spread=30,
                        c_filter=0,
                        points=16,
                        ):
    y_filter_range = np.linspace(y_filter-y_filter_spread/2,
                                    y_filter+y_filter_spread/2,
                                    points)
    m_filter_range = np.linspace(m_filter-m_filter_spread/2,
                                    m_filter+m_filter_spread/2,
                                    points)
    rgb = np.zeros((np.size(y_filter_range), np.size(m_filter_range), 3))
    for i, y_filter in enumerate(y_filter_range):
        for j, m_filter in enumerate(m_filter_range):
            emulsion.expose(self.midgray_rgb, apply_cctf_decoding=False)
            filtered_illuminant = dichroic_filters.apply(print_illuminant, values=[y_filter, m_filter, c_filter])
            self.print(emulsion, filtered_illuminant)
            rgb[j,i] = self.scan(viewing_illuminant)
    colorfullness = np.mean(np.abs(rgb - np.mean(rgb, axis=2)[:,:,None]), axis=2)
    _, ax = plt.subplots()
    dy = (y_filter_range[1]-y_filter_range[0])/2
    dm = (m_filter_range[1]-m_filter_range[0])/2
    filter_extent = [y_filter_range[0]-dy, y_filter_range[-1]+dy,
                        m_filter_range[0]-dm, m_filter_range[-1]+dm]
    ax.imshow(rgb, extent=filter_extent, origin='lower')
    levels = np.array([0.01, 0.02, 0.05, 0.1])
    X, Y = np.meshgrid(y_filter_range, m_filter_range)
    cs = ax.contour(X, Y, colorfullness, levels, colors='k')
    ax.clabel(cs, inline=True, fontsize=6)
    # ax.imshow(colorfullness, extent=filter_extent, origin='lower', cmap='gray_r')
    ax.set_xlabel('Y Filter %')
    ax.set_ylabel('M Filter %')
    ax.set_title(emulsion.stock)
    # TODO: in a separate file create a routine to retrive filter values and create a database of them for all film stocks

def plot_midgray_density_test(self, exposure_bias=1):
    biased_midgray = self.midgray_rgb * exposure_bias
    density_midgray = self.expose(biased_midgray,
                                    color_space='sRGB',
                                    apply_cctf_decoding=False,
                                    exposure=1,
                                    save_density=False)
    _, ax = plt.subplots()
    wavelengths = self.wavelengths
    if self.type=='negative':
        ax.plot(wavelengths, self.dye_density[:,3])
        ax.plot(wavelengths, self.dye_density[:,4])
        ax.plot(wavelengths, density_midgray[0,0])
        ax.legend(('Minimum', 'Midgray', 'Midgray Simulated'))
    if np.logical_or(self.type=='positive', self.type=='paper'):
        ax.plot(wavelengths, np.sum(self.dye_density, axis=1), label='Midgray')
        ax.plot(wavelengths, density_midgray[0,0], color='k', label='Midgray Simulated')
        ax.legend()
    ax.set_xlabel('Wavelength (nm)')
    ax.set_ylabel('Density')
    ax.set_title(self.stock)
    
def grain_test(self,
                multilayer_grain=True,
                samples=256):
    loge = self.density_curves.log_exposure
    gradient_image = 10**loge[None,:,None] * np.ones((samples,1,3))
    area_densitometer_aperture = (48/2)**2*np.pi # um2
    pixel_size_equivalent = np.sqrt(area_densitometer_aperture)
    film_format_equivalent = pixel_size_equivalent*np.max(gradient_image.shape[0:2])/1000 # mm
    density_cmy = self.expose(gradient_image,
                                color_space='sRGB',
                                apply_cctf_decoding=False,
                                save_density=False,
                                add_grain=True,
                                multilayer_grain=multilayer_grain,
                                return_density_cmy=True,
                                film_format=film_format_equivalent)

    grain_rms = np.std(density_cmy, axis=0)
    channels = ['r','g','b']
    colors = ['tab:red','tab:green','tab:blue']
    _, ax = plt.subplots()
    for i, ch in enumerate(channels):
        ax.plot(loge, grain_rms[:,i]*1000, color=colors[i], label=ch)
    # ax.plot(loge, np.mean(density_cmy + self.density_curves.D_min, axis=0))
    ax.set_xlabel('Log Exposure')
    ax.set_yscale('log')
    ax.set_ylabel('RMS Granularity x1000')
    ax.legend()

def test_exposure_bias(self, illuminant):
    gray_scale = np.logspace(-3,3,256)
    gray_scale_rgb = gray_scale[:,None,None] * np.ones((3))
    print(gray_scale_rgb.shape)
    # density_midgray= self.expose(gray_scale_rgb,
    #                              color_space='sRGB',
    #                              apply_cctf_decoding=False,
    #                              exposure=1,
    #                              save_density=True)
    gray_scale_image = self.scan(illuminant, apply_cctf_encoding=False)
    gray_scale_image -= np.min(gray_scale_image, axis=0)
    gray_scale_image /= np.max(gray_scale_image, axis=0)
    _, ax = plt.subplots()
    ax.plot(np.log10(gray_scale), gray_scale_image[:,0,0], color='r')
    ax.plot(np.log10(gray_scale), gray_scale_image[:,0,1], color='g')
    ax.plot(np.log10(gray_scale), gray_scale_image[:,0,2], color='b')
    ax.plot(np.log10(gray_scale), np.mean(gray_scale_image, axis=2)[:,0], color='gray', linestyle='--')
    ax.plot([0, 0],[0,0.184], color='gray')
    ax.plot([np.log10(gray_scale[0]),0],[0.184,0.184], color='gray')
    ax.plot([-1.67,-1.67],[0,1], color='gray', linestyle='--')
    ax.plot([0.735,0.735],[0,1], color='gray', linestyle='--')
    ax.legend(['r','g','b','mean','midgray'])
    ax.set_ylim((0,1))
    ax.set_xlabel('Log scaled-exposure')
    ax.set_ylabel('Normalized linear rgb value')

def plot_density_curves(self):
    n_wavelength = self.image_density.shape[2]
    n_pixel = self.image_density.shape[0] * self.image_density.shape[1]
    density_curves = np.reshape(self.image_density, (n_pixel, n_wavelength))
    density_curves = density_curves.transpose()
    _, ax = plt.subplots()
    ax.plot(self.wavelength, density_curves)

def plot_chromaticity(self, ax=None, color='k'):
    xy, _ = cromaticity_from_spectral_data(self.log_sensitivity)
    xy_w, _ = cromaticity_from_spectral_data(Illuminant(self.reference_white).spectral_power)
    triangle = plt.Polygon(xy.transpose(), facecolor=[0,0,0,0.05], edgecolor=color)

    # _, ax = colour.plotting.plot_chromaticity_diagram_CIE1931()
    if ax==None:
        _, ax = plt.subplots()
    ax.add_patch(triangle)
    ax.scatter(xy_w[0], xy_w[1], color=color)
    ax.set_xlim((0,1))
    ax.set_ylim((0,1))
    ax.axis('equal')
    ax.set_xlabel('x Chromaticity')
    ax.set_ylabel('y Chromaticity')
