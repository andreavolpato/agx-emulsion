import numpy as np
import matplotlib.pyplot as plt
import copy

from agx_emulsion.model.process import photo_params, photo_process

class TestStrip:
    def __init__(self,
                 image,
                 base_params=photo_params(),
                 crop_center=(0.5, 0.5),
                 crop_size=(0.2, 1.0),
                 resize_factor=0.1,
                 steps=7,
                 title='Test Strip',
                 stack='h',
                 rotate=False,
                 line_dividers=False,
                 ):
        self.image = image
        if rotate:
            self.image = np.rot90(self.image)
        self.base_params = base_params
        self.stack = stack
        self.steps = steps
        self.title = title
        self.labels = []
        self.line_dividers = line_dividers
        
        self.crop_center = crop_center
        self.crop_size = crop_size
        self.resize_factor = resize_factor
        self.clean_params()
    
    def clean_params(self, steps=7):
        self.steps = steps
        self.params = []
        self.base_params.io.crop = True
        self.base_params.io.crop_center = self.crop_center
        self.base_params.io.crop_size = self.crop_size
        self.base_params.io.preview_resize_factor = self.resize_factor
        for i in np.arange(self.steps):
            p = copy.copy(self.base_params)
            p.label=f'{i}'
            self.params.append(p)
    
    def process(self, plot=True):
        strip, labels = self._compute(self.image, self.params, self.title,
                        stack=self.stack, plot=True)
        self.labels = labels
        if plot:
            fig = self._plot(strip, self.steps, labels, self.title, self.stack, self.line_dividers)
            return fig
        else: return strip
    
    def negative_exposure_ramp(self, values=[-3, -2, -1, 0, 1, 2, 3]):
        self.clean_params(steps=np.size(values))
        self.title = 'Negative Exposure EV'
        for p, v in zip(self.params, values):
            p.camera.exposure_compensation_ev = v
            p.label = f'{v:.0f}'
        
    def print_exposure_ramp(self, values=[0.3, 0.5, 0.7, 1.0, 1.5, 2.0, 3.0]):
        self.clean_params(steps=np.size(values))
        self.title = 'Print Exposure'
        for p, v in zip(self.params, values):
            p.enlarger.print_exposure = v
            p.label = f'{v:.2f}'
    
    def grain_ramp(self, values=[0.05, 0.1, 0.2, 0.4, 0.8, 1.6]):
        self.clean_params(steps=np.size(values))
        self.title = 'Grain Particle Area (um$^2$)'
        for p, v in zip(self.params, values):
            p.negative.grain.agx_particle_area_um2 = v
            p.label = f'{v:.2f}'
            
    def dir_couplers_ramp(self, values=[0.0, 0.5, 1.0, 1.5, 2.0]):
        self.clean_params(steps=np.size(values))
        self.title = 'DIR Couplers Amount'
        for p, v in zip(self.params, values):
            p.negative.dir_couplers.amount_rgb = v*np.ones(3)
            p.label = f'{v:.2f}'
    
    def glare_ramp(self, values=[0.02, 0.05, 0.1, 0.2, 0.4]):
        self.clean_params(steps=np.size(values))
        self.title = 'Amount of Glare Light (%)'
        for p, v in zip(self.params, values):
            p.print_paper.glare.percent = v
            p.label = f'{v:.2f}'
    

    def _compute(self, image, conditions, title,
                        stack='h', plot=True):
        labels = []
        for i, p in enumerate(conditions):
            section = photo_process(image, p)
            if stack == 'h':
                if i == 0:
                    strip = np.zeros((section.shape[0], 0, section.shape[2]))
                strip = np.hstack([strip, section])
            if stack == 'v':
                if i == 0:
                    strip = np.zeros((0, section.shape[1], section.shape[2]))
                strip = np.vstack([strip, section])
            labels.append(p.label)
        return strip, labels

    def _plot(self, strip, n_conditions, labels, title, stack='h', lines=False):
        ticks = np.double(np.arange(n_conditions)) + 0.5
        ticks /= n_conditions
        fig, ax = plt.subplots()
        ax.imshow(strip)
        if stack=='h':
            ticks *= strip.shape[1]
            ax.set_yticks([])
            ax.set_xticks(ticks, labels)
            ax.xaxis.tick_top()
            ax.xaxis.set_label_position('top')
            if lines:
                for i in np.arange(n_conditions-1):
                    i = np.double(i)
                    ax.axvline((i+1)*np.double(strip.shape[1])/n_conditions-0.5, color='w', linewidth=0.5)
            ax.set_xlabel(title)
        if stack=='v':
            ticks *= strip.shape[0]
            ax.set_xticks([])
            ax.set_yticks(ticks, labels)
            if lines:
                for i in np.arange(n_conditions-1):
                    i = np.double(i)
                    ax.axhline((i+1)*np.double(strip.shape[0])/n_conditions-0.5, color='w', linewidth=0.5)
            ax.set_ylabel(title)
        ax.spines['top'].set_visible(False)
        ax.spines['bottom'].set_visible(False)
        ax.spines['left'].set_visible(False)
        ax.spines['right'].set_visible(False)
        ax.tick_params(length=0)
        return fig


if __name__ == '__main__':
    from agx_emulsion.utils.io import load_image_oiio
    
    image = load_image_oiio('img/targets/cc11.tiff')
    p = photo_params(negative='kodak_portra_400_auc')
    p.io.input_cctf_decoding = True
      
    strip = TestStrip(image, base_params=p, stack='h', crop_size=(1.0,1.0), crop_center=(0.5,0.85), resize_factor=0.05, rotate=True)
    strip.negative_exposure_ramp(values=[-3, -2, -1, 0, 1, 2, 3, 4, 5, 6])
    fig = strip.process()
    plt.show()
