import numpy as np
import scipy
import copy
from enum import Enum

from agx_emulsion.model.process import photo_params, photo_process, AgXPhoto
from agx_emulsion.model.illuminants import standard_illuminant
from agx_emulsion.utils.io import save_ymc_filter_values

# TODO: move this file to scripts to produce YMC neutral values

class FilmStocks(Enum):
    kodak_ektar_100 = 'kodak_ektar_100_auc'
    kodak_portra_160 = 'kodak_portra_160_auc'
    kodak_portra_400 = 'kodak_portra_400_auc'
    kodak_portra_800 = 'kodak_portra_800_auc'
    kodak_portra_800_push1 = 'kodak_portra_800_push1_auc'
    kodak_portra_800_push2 = 'kodak_portra_800_push2_auc'
    kodak_gold_200 = 'kodak_gold_200_auc'
    kodak_ultramax_400 = 'kodak_ultramax_400_auc'
    kodak_vision3_50d = 'kodak_vision3_50d_uc'
    # kodak_vision3_50d_uh = 'kodak_vision3_50d_uh'
    # kodak_vision3_50d_uhc = 'kodak_vision3_50d_uhc'
    fujifilm_pro_400h = 'fujifilm_pro_400h_auc'
    fujifilm_xtra_400 = 'fujifilm_xtra_400_auc'
    # fujifilm_pro_400h_auhc = 'fujifilm_pro_400h_auhc'
    # fujifilm_pro_400h_auh = 'fujifilm_pro_400h_auh'
    # fujifilm_pro_400h_aucc = 'fujifilm_pro_400h_aucc'
    fujifilm_c200 = 'fujifilm_c200_auc'
    # kodak_portra_400_au = 'kodak_portra_400_au'
    # kodak_ultramax_400_au = 'kodak_ultramax_400_au'
    # kodak_gold_200_au = 'kodak_gold_200_au'
    # kodak_vision3_50d_u = 'kodak_vision3_50d_u'
    # fujifilm_pro_400h_au = 'fujifilm_pro_400h_au'
    # fujifilm_c200_au = 'fujifilm_c200_au'

class PrintPapers(Enum):
    # kodak_ultra_endura = 'kodak_ultra_endura_uc' # problematic
    kodak_endura_premier = 'kodak_endura_premier_uc'
    kodak_ektacolor_edge = 'kodak_ektacolor_edge_uc'
    kodak_supra_endura = 'kodak_supra_endura_uc'
    kodak_portra_endura = 'kodak_portra_endura_uc'
    fujifilm_crystal_archive_typeii = 'fujifilm_crystal_archive_typeii_uc'
    kodak_2383 = 'kodak_2383_uc'
    kodak_2393 = 'kodak_2393_uc'

class Illuminants(Enum):
    lamp = 'TH-KG3'
    # bulb = 'T'
    # cine = 'K75P'
    # led_rgb = 'LED-RGB1'

def fit_print_filters(profile):
    p = copy.copy(profile)
    p.debug.deactivate_spatial_effects = True
    p.debug.deactivate_stochastic_effects = True
    p.print_paper.glare.compensation_removal_factor = 0.0
    p.io.input_cctf_decoding = False
    p.io.input_color_space = 'sRGB'
    p.io.resize_factor = 1.0
    p.camera.auto_exposure = False
    p.enlarger.print_exposure_compensation = False
    midgray_rgb = np.array([[[0.184, 0.184, 0.184]]])
    c_filter = p.enlarger.c_filter_neutral
    
    def midgray_print(ymc_values, print_exposure):
        p.enlarger.y_filter_neutral = ymc_values[0]
        p.enlarger.m_filter_neutral = ymc_values[1]
        p.enlarger.print_exposure = print_exposure
        rgb = photo_process(midgray_rgb, p)
        return rgb
    def evaluate_residues(x):
        res = midgray_print([x[0], x[1], c_filter], x[2])
        res = res - midgray_rgb
        res = res.flatten()
        return res
    y_filter = p.enlarger.y_filter_neutral
    m_filter = p.enlarger.m_filter_neutral
    x0 = [y_filter, m_filter, 1.0]
    x = scipy.optimize.least_squares(evaluate_residues, x0, bounds=([0, 0, 0], [1, 1, 10]),
                                     ftol=1e-6, xtol=1e-6, gtol=1e-6,
                                     method='trf')
    print(p.negative.info.stock)
    print('Total residues:',np.sum(np.abs(evaluate_residues(x.x))),'<-',evaluate_residues(x0))
    print('Fitted Filters :'+f"[ {x.x[0]:.2f}, {x.x[1]:.2f}, {c_filter:.2f} ]")
    profile.enlarger.y_filter_neutral = x.x[0]
    profile.enlarger.m_filter_neutral = x.x[1]
    profile.enlarger.c_filter_neutral = c_filter
    return x.x[0], x.x[1], evaluate_residues(x.x)

if __name__=='__main__':
    import matplotlib.pyplot as plt
    plot_data = False
    density_midgray_test = False
    print_filter_test = False
    spread = 0.2
    fit_filters = True
        
    # ymc_filters = copy.copy(ymc_filters_0)
        
    d55 = standard_illuminant(type='D55', return_class=True)
    
    
    if density_midgray_test:
        vision50d.plot_midgray_density_test()
        portra400.plot_midgray_density_test()
        ektacolor.plot_midgray_density_test()
        portra_endura.plot_midgray_density_test()
        # provia100f.plot_midgray_density_test()
    
    def make_ymc_filters_dictionary(PrintPapers, Illuminants, FilmStocks):
        ymc_filters_0 = {}
        residues = {}
        for paper in PrintPapers:
            ymc_filters_0[paper.value] = {}
            residues[paper.value] = {}
            for light in Illuminants:
                ymc_filters_0[paper.value][light.value] = {}
                residues[paper.value][light.value] = {}
                for film in FilmStocks:
                    ymc_filters_0[paper.value][light.value][film.value] = [0.90, 0.70, 0.35]
                    residues[paper.value][light.value][film.value] = 0.184
        ymc_filters = copy.copy(ymc_filters_0)
        save_ymc_filter_values(ymc_filters)
        return ymc_filters, residues
    
    def fit_all_stocks(ymc_filters, residues, iterations=5, randomess_starting_points=0.5):

        ymc_filters_out = copy.deepcopy(ymc_filters)
        r = randomess_starting_points
        
        for i in range(iterations):
            for paper in PrintPapers:
                print(' '*20)
                print('#'*20)
                print(paper.value)
                for light in Illuminants:
                    print('-'*20)
                    print(light.value)
                    for stock in FilmStocks:
                        if residues[paper.value][light.value][stock.value] > 5e-4:
                            y0 = ymc_filters[paper.value][light.value][stock.value][0]
                            m0 = ymc_filters[paper.value][light.value][stock.value][1]
                            c0 = ymc_filters[paper.value][light.value][stock.value][2]
                            y0 = np.clip(y0, 0, 1)*(1-r) + np.random.uniform(0,1)*r
                            m0 = np.clip(m0, 0, 1)*(1-r) + np.random.uniform(0,1)*r
                            
                            p = photo_params(negative=stock.value, print_paper=paper.value, ymc_filters_from_database=False)
                            p.enlarger.illuminant = light.value
                            p.enlarger.y_filter_neutral = y0
                            p.enlarger.m_filter_neutral = m0
                            p.enlarger.c_filter_neutral = c0
                    
                            yf, mf, res = fit_print_filters(p)
                            ymc_filters_out[paper.value][light.value][stock.value] = [yf, mf, c0]
                            residues[paper.value][light.value][stock.value] = np.sum(np.abs(res))
        return ymc_filters_out
    
    ymc_filters, residues = make_ymc_filters_dictionary(PrintPapers, Illuminants, FilmStocks)
    ymc_filters = fit_all_stocks(ymc_filters, residues, iterations=20)
    save_ymc_filter_values(ymc_filters)

    if print_filter_test:
        for paper in PrintPapers:
            for stock in FilmStocks:
                for light in Illuminants:
                    if stock.value.type=='negative':
                        YMC = ymc_filters[paper.value][light.value][stock.value]
                        paper.value.print_filter_test(stock.value, light.value[:], d55[:],
                                                        y_filter=YMC[0],
                                                        m_filter=YMC[1],
                                                        c_filter=YMC[2],
                                                        y_filter_spread=spread,
                                                        m_filter_spread=spread)
    plt.show()
    
    # TODO: find a way to visualize color primaries of print and negatives
    # maybe we could argue on the saturation and quality from them
    # TODO: create a generic high performance paper model with tunable gamma and maybe saturation
    # TODO: make a small routine to fit dye density
    # TODO: make a small routine to fit dmin and dmid with a simplified dye density model
    # TODO: make a test chart to verify that i am not killing the greens in portra or other stocks
    # TODO: create a simple way to mix data of different paper-films
        